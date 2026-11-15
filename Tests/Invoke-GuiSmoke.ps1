<#
.SYNOPSIS
    Smoke test of the graphical interface: starts Start-AVDTune.ps1 off-screen with a fake machine and a temporary state folder
    (no elevation needed, nothing of this computer is changed, nothing under C:\ProgramData\AVDTune), drives every page, the theme
    switch, the new image version, protocol and change log, and checks the results. Screenshots of the pages land in -OutDir.
.EXAMPLE
    .\Tests\Invoke-GuiSmoke.ps1
#>
# Default -OutDir: one folder per checkout (AVDTuneSmoke-<folder of the repo>), so two worktrees can run the smoke side by side without sharing screenshots
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) ('AVDTuneSmoke-' + (Split-Path $repo -Leaf)) }
# The folder is cleared without following links (a junction in it is removed itself, never what it points to); a drive root is never cleared
Import-Module (Join-Path $repo 'Modules\AVDTune.Trust.psm1') -Force
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ($OutDir -eq [IO.Path]::GetPathRoot($OutDir)) { throw "-OutDir must not be a drive root: $OutDir" }
"Smoke output folder: $OutDir"
# Only a folder that is ours is cleared: the name starts with AVDTuneSmoke or the marker file is in it (written when the folder is created)
$marker = Join-Path $OutDir '.avdtune-smoke'
if ((Test-Path -LiteralPath $OutDir) -and (Split-Path $OutDir -Leaf) -notlike 'AVDTuneSmoke*' -and -not (Test-Path -LiteralPath $marker)) { throw "-OutDir $OutDir is not a smoke folder (name starting with AVDTuneSmoke or a .avdtune-smoke file in it); nothing was deleted." }
Remove-AVDTuneFolderNoFollow $OutDir
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
[IO.File]::WriteAllText($marker, 'AVDTune GUI smoke output folder; may be cleared by the next run.')
$results = Join-Path $OutDir 'results.txt'
# The theme is pinned (otherwise it follows this computer's Windows setting)
New-Item -ItemType Directory -Path (Join-Path $OutDir 'state\config') -Force | Out-Null
'{"Theme":"Light","ProtocolLanguage":"en"}' | Set-Content (Join-Path $OutDir 'state\config\ui.json')

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'Start-AVDTune.ps1')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# a clean module path (an inherited PowerShell 7 path breaks the Windows PowerShell modules)
$psi.EnvironmentVariables['PSModulePath'] = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$psi.EnvironmentVariables['AVDTUNE_ROOT'] = (Join-Path $OutDir 'state')
$psi.EnvironmentVariables['AVDTUNE_FAKE'] = (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
$psi.EnvironmentVariables['AVDTUNE_SMOKE'] = (Join-Path $PSScriptRoot 'GuiSmokeDriver.ps1')
$psi.EnvironmentVariables['AVDTUNE_SMOKE_OUT'] = $OutDir
$process = [System.Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(5 * 60 * 1000)) { $process.Kill(); throw 'The GUI smoke test did not finish within 5 minutes.' }
if ($stderr.Result.Trim()) { '--- stderr ---'; $stderr.Result }
if (-not (Test-Path $results)) { '--- stdout ---'; $stdout.Result; throw 'The GUI smoke test wrote no results.' }
Get-Content $results
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL*' }).Count
if (Test-Path 'C:\ProgramData\AVDTune') { "NOTE C:\ProgramData\AVDTune exists on this computer (not made by this test: it uses $OutDir\state)." }
"Screenshots: $OutDir"
if ($failed -gt 0) { throw "$failed check(s) failed." }
'All checks passed.'
