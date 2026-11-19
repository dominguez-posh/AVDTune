#requires -Version 5.1
<#
.SYNOPSIS
    AVD-Benchmark stand-alone: the entry script of the package AVD-Benchmark-<version>.zip (docs\benchmark-design.md section 7, plan 6b, #90).
    Runs only the benchmark-only mode of the engine in the package (Modules\AVDTune.Benchmark.psm1): no window, no sign-in, no Azure, no setup.
.DESCRIPTION
    The package is made by Tools\New-AVDBenchmarkPackage.ps1 from a finished AVDTune release. This script lies in its root next to package-manifest.json.
    Order (nothing of the package is loaded before step 4):
      1. First statement: PSModulePath of this process from the Windows folders, set with .NET (the rule of Start-AVDTune.ps1, #73).
      2. Windows PowerShell 5.1.
      3. The package is checked against package-manifest.json: type-checked manifest (Product AVD-Benchmark, Schema 1, Entry = this script), every listed file is
         there with its size and SHA256, no file that is not listed, no link anywhere. -ManifestSha256 pins the manifest itself (the value is in manifest.json next to
         the published ZIP). Without it the check finds damage and missing files, but not somebody who changed files and manifest together.
         -VerifyOnly stops here (exit 0 when the package is complete); it needs no administrator.
      4. Elevated only. The package folder, everything in it and the folders above it must be changeable by administrators only (owner Administrators, SYSTEM or
         TrustedInstaller, no write access for anyone else, no link): otherwise a file could be swapped between the check and the start. Extract the package below
         Program Files.
      5. TEMP/TMP of this process in a new admin-only folder (#54), then the modules of the package, the module path check, one instance (mutex Global\AVDTune),
         the state folder C:\ProgramData\AVDTune (checked like AVDTune does), a repair after an interrupted benchmark.
      6. Invoke-AVDTuneBenchmark -Kind benchmark-only with the system name and the notes; the result stays in the state folder and, with -OutDir, a copy of the
         checked result file goes there (for "Import comparison system" in AVDTune).
    The measure program AVDTune.Bench.exe is started by the engine only after its own check (Open-AVDTuneVerifiedBenchExe); a refusal is shown as the reason why
    the benchmark did not start. This script never starts a program itself.
    Exit codes: 0 done, 1 the benchmark failed or did not start, 2 the package check failed, 3 not Windows PowerShell 5.1 or not elevated, 4 the folder is not
    admin-only, 5 AVDTune or another benchmark is running.
.PARAMETER Name
    The name of the measured system (1 to 80 characters), required for a run.
.PARAMETER Notes
    Notes for the result (up to 500 characters).
.PARAMETER Mode
    Full (default) or Quick.
.PARAMETER OutDir
    An existing folder that gets a copy of the result file (avd-benchmark-<run id>.json).
.PARAMETER ManifestSha256
    The SHA256 of package-manifest.json as published with the package; the manifest must have exactly this hash.
.PARAMETER VerifyOnly
    Only check the package against its manifest and stop.
#>
[CmdletBinding()]
param([string]$Name, [string]$Notes, [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [string]$OutDir, [string]$ManifestSha256, [switch]$VerifyOnly)

# First statement, before any cmdlet (#73): modules only from the system folders, never from the admin's Documents or HKCU\Environment. The same text as in Start-AVDTune.ps1.
[Environment]::SetEnvironmentVariable('PSModulePath', [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'System32\WindowsPowerShell\v1.0\Modules') + ';' + [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'WindowsPowerShell\Modules'), 'Process')
$ErrorActionPreference = 'Stop'

function Stop-AVDBenchmark([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine("AVD-Benchmark: $Text")
    exit $Code
}

function Get-AVDBenchmarkSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-AVDBenchmarkRelativePath([string]$Path) {
    # the rule of Tools\New-AVDBenchmarkPackage.ps1: known characters, no climbing, no trailing dot or space, no device names; \A and \z, never ^ and $
    $Path.Length -le 200 -and $Path -cmatch '\A[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*\z' -and $Path -notmatch '(\A|/)\.{1,2}(/|\z)' -and $Path -notmatch '[. ](/|\z)' -and $Path -notmatch '(?i)(\A|/)(con|prn|aux|nul|com\d|lpt\d)(\.[^/]*)?(/|\z)'
}

function Get-AVDBenchmarkTree([string]$Root) {
    # Every folder and file below the root without following a link: Path (relative, '/'), Full, Folder, Link
    $items = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object IO.DirectoryInfo $Root))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($entry in $dir.GetFileSystemInfos()) {
            $link = (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            $folder = ($entry -is [IO.DirectoryInfo])
            [void]$items.Add([pscustomobject]@{ Path = $entry.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/'); Full = $entry.FullName; Folder = $folder; Link = $link })
            if ($folder -and -not $link) { $stack.Push($entry) }
            if ($items.Count -gt 5000) { throw 'The package folder holds more than 5000 entries: this is not a package.' }
        }
    }
    $items.ToArray()
}

function Test-AVDBenchmarkPackage {
    <#
        Checks the folder against package-manifest.json. Returns Problems (empty: the package is complete and unchanged against its manifest), Version, Files (count)
        and ManifestSha256. Reads only; nothing of the package is run or imported.
    #>
    param([Parameter(Mandatory)][string]$Root, [string]$PinnedSha256)
    $problems = New-Object System.Collections.ArrayList
    $done = { param($Version, $Count, $Hash) [pscustomobject]@{ Problems = @($problems); Version = [string]$Version; Files = [int]$Count; ManifestSha256 = [string]$Hash } }
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $manifestPath = [IO.Path]::Combine($Root, 'package-manifest.json')
    $info = New-Object IO.FileInfo $manifestPath
    if (-not $info.Exists) { [void]$problems.Add('package-manifest.json is missing: this folder is not an AVD-Benchmark package.'); return (& $done '' 0 '') }
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add('package-manifest.json is a link.'); return (& $done '' 0 '') }
    if ($info.Length -gt 1MB) { [void]$problems.Add('package-manifest.json is larger than 1 MB.'); return (& $done '' 0 '') }
    $manifestHash = Get-AVDBenchmarkSha256 $manifestPath
    if ($PinnedSha256) {
        if ($PinnedSha256 -notmatch '\A[0-9a-fA-F]{64}\z') { [void]$problems.Add('-ManifestSha256 is not a SHA256 (64 hex characters).'); return (& $done '' 0 $manifestHash) }
        if ($manifestHash -ne $PinnedSha256.ToLowerInvariant()) { [void]$problems.Add("package-manifest.json does not have the SHA256 given with -ManifestSha256 (it has $manifestHash)."); return (& $done '' 0 $manifestHash) }
    }
    $m = $null
    try { $m = [IO.File]::ReadAllText($manifestPath).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { [void]$problems.Add('package-manifest.json is not JSON.'); return (& $done '' 0 $manifestHash) }
    $prop = { param($o, $n) if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.PSObject.Properties[$n].Value } else { $null } }
    $schema = & $prop $m 'Schema'; $product = & $prop $m 'Product'; $version = & $prop $m 'Version'; $entry = & $prop $m 'Entry'
    if ($schema -isnot [int] -or $schema -ne 1) { [void]$problems.Add('The manifest has no Schema 1.') }
    if ($product -isnot [string] -or $product -cne 'AVD-Benchmark') { [void]$problems.Add('The manifest is not one of an AVD-Benchmark package.') }
    if ($version -isnot [string] -or $version -notmatch '\A\d+\.\d+\.\d+(-ea\.\d+)?\z') { [void]$problems.Add('The version of the manifest is not x.y.z or x.y.z-ea.N.'); $version = '' }
    if ($entry -isnot [string] -or $entry -cne 'Invoke-AVDBenchmark.ps1') { [void]$problems.Add('The manifest does not name Invoke-AVDBenchmark.ps1 as the entry.') }
    $files = @(& $prop $m 'Files' | Where-Object { $null -ne $_ })
    if ($files.Count -eq 0 -or $files.Count -gt 500) { [void]$problems.Add('The manifest lists no files (or more than 500).'); return (& $done $version 0 $manifestHash) }
    $listed = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) {
        $path = & $prop $f 'Path'; $size = & $prop $f 'Size'; $hash = & $prop $f 'Sha256'
        if ($path -isnot [string] -or -not (Test-AVDBenchmarkRelativePath $path)) { [void]$problems.Add('The manifest has an unsafe path.'); continue }
        if (($size -isnot [int] -and $size -isnot [long]) -or $size -lt 0) { [void]$problems.Add("No size for $path in the manifest."); continue }
        if ($hash -isnot [string] -or $hash -cnotmatch '\A[0-9a-f]{64}\z') { [void]$problems.Add("No SHA256 for $path in the manifest."); continue }
        if ($listed.ContainsKey($path)) { [void]$problems.Add("The manifest lists $path twice."); continue }
        $listed[$path] = [pscustomobject]@{ Size = [int64]$size; Sha256 = $hash }
    }
    foreach ($need in 'Invoke-AVDBenchmark.ps1', 'Modules/AVDTune.psm1', 'Modules/AVDTune.Benchmark.psm1', 'Bench/data/benchmark-B1.0.json') { if (-not $listed.ContainsKey($need)) { [void]$problems.Add("The manifest does not list $need.") } }
    if ($problems.Count -gt 0) { return (& $done $version $listed.Count $manifestHash) }
    $tree = @(Get-AVDBenchmarkTree $Root)
    foreach ($t in $tree) {
        if ($t.Link) { [void]$problems.Add("$($t.Path) is a link.") }
        elseif (-not $t.Folder -and $t.Path -ne 'package-manifest.json' -and -not $listed.ContainsKey($t.Path)) { [void]$problems.Add("$($t.Path) is not listed in the manifest.") }
    }
    $onDisk = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $tree) { if (-not $t.Folder -and -not $t.Link) { $onDisk[$t.Path] = $t } }
    foreach ($path in $listed.Keys) {
        if (-not $onDisk.ContainsKey($path)) { [void]$problems.Add("$path is missing."); continue }
        $full = $onDisk[$path].Full
        if ((New-Object IO.FileInfo $full).Length -ne $listed[$path].Size) { [void]$problems.Add("$path does not have the size of the manifest."); continue }
        if ((Get-AVDBenchmarkSha256 $full) -ne $listed[$path].Sha256) { [void]$problems.Add("$path does not match the SHA256 of the manifest.") }
    }
    & $done $version $listed.Count $manifestHash
}

function Get-AVDBenchmarkAclProblems {
    <#
        Why somebody without administrator rights could change the package between the check and the start: the root, every folder and file in it and the folders
        above it (up to, not including, the drive root) must have an owner Administrators, SYSTEM or TrustedInstaller and no allow rule with a write right for anyone
        else (the rule and the rights of Get-AVDTuneAclProblems in AVDTune.psm1, inherit-only rules count), and must not be links. The drive root itself must not let
        others delete or take over what is in it.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-0')
    $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000   # WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, ChangePermissions, TakeOwnership, GENERIC_WRITE, GENERIC_ALL
    $rootMask = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000   # on the drive root: DeleteChild, Delete, ChangePermissions, TakeOwnership, GENERIC_ALL
    $problems = New-Object System.Collections.ArrayList
    $look = {
        param([string]$Path, [bool]$Folder, [int]$Mask, [bool]$OwnerCounts, [bool]$SkipInheritOnly)
        try {
            $item = if ($Folder) { New-Object IO.DirectoryInfo $Path } else { New-Object IO.FileInfo $Path }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add("$Path is a link"); return }
            $acl = $item.GetAccessControl()
            $owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($OwnerCounts -and $owner -notin $trusted) { [void]$problems.Add("$Path belongs to $owner") }
            $others = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and -not ($SkipInheritOnly -and (([int]$_.PropagationFlags -band 2) -ne 0)) -and ((([int]$_.FileSystemRights) -band $Mask) -ne 0) -and [string]$_.IdentityReference.Value -notin $trusted } | ForEach-Object { [string]$_.IdentityReference.Value } | Sort-Object -Unique)
            if ($others.Count -gt 0) { [void]$problems.Add("$Path can be changed by $($others -join ', ')") }
        }
        catch { [void]$problems.Add("$Path cannot be checked ($($_.Exception.Message))") }
    }
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($Root -notmatch '\A[A-Za-z]:\\') { return @("$Root is not a folder on a local drive") }
    $drive = $Root.Substring(0, 3)
    & $look $drive $true $rootMask $false $true   # a rule of the drive root that only applies to what is below it shows up there (inherited) and is judged there
    $parent = $Root
    while ($parent -and $parent.Length -gt 3) { & $look $parent $true $writeMask $true $false; $parent = [IO.Path]::GetDirectoryName($parent) }
    foreach ($t in @(Get-AVDBenchmarkTree $Root)) { if ($problems.Count -ge 20) { break }; & $look $t.Full $t.Folder $writeMask $true $false }
    @($problems)
}

if ($PSVersionTable.PSEdition -ne 'Desktop') { Stop-AVDBenchmark 3 "This script needs Windows PowerShell 5.1: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" }

# 3. the package against its manifest, before anything of it is loaded
$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$check = $null
try { $check = Test-AVDBenchmarkPackage -Root $packageRoot -PinnedSha256 $ManifestSha256 } catch { Stop-AVDBenchmark 2 "The package could not be checked: $($_.Exception.Message)" }
if ($check.Problems.Count -gt 0) { Stop-AVDBenchmark 2 ("The package does not match its manifest, nothing was started: " + ((@($check.Problems) | Select-Object -First 10) -join ' ')) }
[Console]::Out.WriteLine("AVD-Benchmark $($check.Version): $($check.Files) files match package-manifest.json (SHA256 $($check.ManifestSha256))$(if (-not $ManifestSha256) { '; the manifest itself is not pinned (-ManifestSha256)' }).")
if ($VerifyOnly) { exit 0 }

# 4. elevated, and a folder that only administrators can change
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Stop-AVDBenchmark 3 'The benchmark needs an administrator session (Run as administrator).' }
$aclProblems = @(Get-AVDBenchmarkAclProblems -Root $packageRoot)
if ($aclProblems.Count -gt 0) { Stop-AVDBenchmark 4 ("The package folder is not protected, so a file could be changed after the check; nothing was started. Extract the package into a folder that only administrators can change (for example below Program Files). " + ((@($aclProblems) | Select-Object -First 5) -join '; ')) }
if (-not $Name) { Stop-AVDBenchmark 1 'Give the measured system a name: -Name "<system name>".' }

# 5. TEMP/TMP of this process (#54, the block of Start-AVDTune.ps1): a new admin-only folder below the Windows TEMP folder until the state folder is verified
$script:BootTemp = [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'Temp', 'AVDTune-' + [guid]::NewGuid().ToString('N'))
$bootAcl = [System.Security.AccessControl.DirectorySecurity]::new(); $bootAcl.SetAccessRuleProtection($true, $false)
$bootSids = @('S-1-5-32-544', 'S-1-5-18')
$bootAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach ($sid in $bootSids) { $bootAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)) }
[void][IO.Directory]::CreateDirectory($script:BootTemp, $bootAcl)
$bootGot = [IO.Directory]::GetAccessControl($script:BootTemp)
$bootRules = @($bootGot.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
if ((([IO.File]::GetAttributes($script:BootTemp) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or -not $bootGot.AreAccessRulesProtected -or $bootGot.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or @($bootRules | Where-Object { $_.IsInherited -or $_.AccessControlType -ne 'Allow' -or $bootSids -notcontains $_.IdentityReference.Value }).Count -gt 0) { Stop-AVDBenchmark 4 "The start folder $($script:BootTemp) is not this script's own (owner, rules or a link)." }
foreach ($n in 'TEMP', 'TMP') { [Environment]::SetEnvironmentVariable($n, $script:BootTemp, 'Process') }

$mutex = $null; $owned = $false; $code = 1
try {
    Import-Module ([IO.Path]::Combine($packageRoot, 'Modules', 'AVDTune.psm1')) -Force
    [void](Set-AVDTuneSafeModulePath)
    $modulePathProblems = @(Get-AVDTuneModulePathProblems)
    if ($modulePathProblems.Count -gt 0) { throw ("A module folder of Windows PowerShell is not admin-only: " + ((@($modulePathProblems) | Select-Object -First 5) -join '; ')) }
    Import-Module ([IO.Path]::Combine($packageRoot, 'Modules', 'AVDTune.Benchmark.psm1')) -Force
    # one instance: not next to AVDTune (the same state folder) and not next to another run of this script
    $mutex = New-Object System.Threading.Mutex($false, 'Global\AVDTune')
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $code = 5; throw 'AVDTune or another benchmark is running on this computer. Close it first.' }
    $stateRoot = Get-AVDTuneRoot
    [void](Initialize-AVDTuneState -Root $stateRoot)
    [void](Set-AVDTuneProcessTemp -StateRoot $stateRoot)
    try { [void](Remove-AVDTuneTreeSafe -Path $script:BootTemp) } catch { }
    $label = @(Test-AVDTuneBenchmarkLabel -Name $Name -Notes $Notes)
    if ($label.Count -gt 0) { throw "The benchmark did not start: $($label -join '; ')." }
    if ($OutDir) {
        $outInfo = New-Object IO.DirectoryInfo ([IO.Path]::GetFullPath($OutDir))
        if (-not $outInfo.Exists -or (($outInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "-OutDir $OutDir is not an existing folder (or it is a link)." }
    }
    $machine = New-AVDTuneMachine
    $bench = New-AVDTuneBenchAdapter
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $repair = Repair-AVDTuneBenchmarkCrash -Machine $machine -Bench $bench -Root $stateRoot -User $user
    if ($repair.Message -and $repair.Message -ne 'Nothing to repair.') { [Console]::Out.WriteLine($repair.Message) }
    $progress = { param($Text, $Percent) [Console]::Out.WriteLine($(if ($null -ne $Percent) { '[{0,3} %] {1}' -f [int]$Percent, $Text } else { "        $Text" })) }
    $run = Invoke-AVDTuneBenchmark -Machine $machine -Bench $bench -Root $stateRoot -Mode $Mode -Kind 'benchmark-only' -User $user -Progress $progress -SystemName $Name -Notes $Notes
    [Console]::Out.WriteLine($run.Summary)
    foreach ($w in @($run.Warnings)) { [Console]::Out.WriteLine("Warning: $w") }
    foreach ($e in @($run.Errors)) { [Console]::Out.WriteLine("Error: $e") }
    [Console]::Out.WriteLine("Result: $($run.Path)")
    if ($OutDir) {
        $copy = [IO.Path]::Combine($outInfo.FullName, "avd-benchmark-$($run.RunId).json")
        [void](Export-AVDTuneBenchmarkResultFile -Root $stateRoot -RunId ([string]$run.RunId) -Path $copy)
        [Console]::Out.WriteLine("Result file for the import as comparison system: $copy")
    }
    $code = 0
}
catch { [Console]::Error.WriteLine("AVD-Benchmark: $($_.Exception.Message)") }
finally {
    if ($mutex) { if ($owned) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose() }
    try { [IO.Directory]::Delete($script:BootTemp) } catch { }   # when still there and empty (not recursive)
}
exit $code
