#requires -Version 5.1
<#
.SYNOPSIS
    Runs all fast checks, each in its own Windows PowerShell 5.1 process with a clean module path, and with -Smoke also the GUI smoke test.
    Nothing here touches the real system: fakes and temporary folders only.
#>
[CmdletBinding()]
param([switch]$Smoke, [ValidateRange(1, 120)][int]$TimeoutMinutes = 20)

$ErrorActionPreference = 'Stop'
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$env:PSModulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$checks = @('Check-Shared.ps1', 'Check-AVDTune.ps1', 'Check-UpdateBlock.ps1', 'Check-Updates.ps1', 'Check-Readiness.ps1', 'Check-FSLogix.ps1', 'Check-Storage.ps1', 'Check-Environment.ps1', 'Check-Start.ps1', 'Check-Protocol.ps1', 'Check-Theme.ps1', 'Check-UiText.ps1', 'Check-Watermark.ps1', 'Check-Shortcut.ps1', 'Check-Release.ps1', 'Check-PublicContent.ps1', 'Check-Benchmark.ps1', 'Check-Tasks.ps1', 'Check-Software.ps1', 'Check-Office.ps1', 'Check-Vdi.ps1', 'Check-Masking.ps1', 'Check-Finish.ps1', 'Check-Optimization.ps1', 'Check-Language.ps1', 'Check-SafeDelete.ps1', 'Check-Custom.ps1')
if ($Smoke) { $checks += 'Invoke-GuiSmoke.ps1' }
$failed = @()
$taskkill = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
foreach ($check in $checks) {
    # Each check in its own process with a time limit (#51): a check that hangs is ended with its whole tree (only the process started here) and reported as
    # TIMEOUT instead of holding the run. stdout and stderr are read asynchronously (a full pipe must not block the child); the exit code and FAIL lines decide.
    $psi = New-Object Diagnostics.ProcessStartInfo $powershell
    $psi.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $check) + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $outRead = $p.StandardOutput.ReadToEndAsync(); $errRead = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutMinutes * 60000)
    if ($timedOut) { & $taskkill /PID $p.Id /T /F 2>&1 | Out-Null; [void]$p.WaitForExit(15000) }
    [void]$outRead.Wait(15000); [void]$errRead.Wait(15000)
    $output = $(if ($outRead.IsCompleted) { $outRead.Result }) + $(if ($errRead.IsCompleted) { $errRead.Result })
    $code = $(if ($timedOut) { -1 } else { $p.ExitCode })
    $p.Dispose()
    $pass = ([regex]::Matches($output, '(?m)^PASS ')).Count
    $fail = ([regex]::Matches($output, '(?m)^FAIL ')).Count
    $ok = ($code -eq 0 -and $fail -eq 0)
    '{0,-22} {1,3} passed, {2} failed  {3}' -f $check, $pass, $fail, $(if ($timedOut) { "TIMEOUT after $TimeoutMinutes min (ended)" } elseif ($ok) { 'OK' } else { 'FAILED' })
    if (-not $ok) { $failed += $check; $output }
}
if ($failed.Count -gt 0) { throw "Failed: $($failed -join ', ')" }
'All checks passed.'
