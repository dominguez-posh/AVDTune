#requires -Version 5.1
<#
.SYNOPSIS
    Runs all fast checks, each in its own Windows PowerShell 5.1 process with a clean module path, and with -Smoke also the GUI smoke test.
    Nothing here touches the real system: fakes and temporary folders only.
#>
[CmdletBinding()]
param([switch]$Smoke)

$ErrorActionPreference = 'Stop'
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$env:PSModulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$checks = @('Check-Shared.ps1', 'Check-AVDTune.ps1', 'Check-UpdateBlock.ps1', 'Check-Updates.ps1', 'Check-Readiness.ps1', 'Check-FSLogix.ps1', 'Check-Storage.ps1', 'Check-Start.ps1', 'Check-Protocol.ps1', 'Check-Theme.ps1', 'Check-Watermark.ps1', 'Check-Shortcut.ps1', 'Check-Release.ps1', 'Check-PublicContent.ps1', 'Check-Benchmark.ps1', 'Check-Tasks.ps1')
if ($Smoke) { $checks += 'Invoke-GuiSmoke.ps1' }
$failed = @()
foreach ($check in $checks) {
    $output = & $powershell -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $check) 2>&1 | Out-String
    $pass = ([regex]::Matches($output, '(?m)^PASS ')).Count
    $fail = ([regex]::Matches($output, '(?m)^FAIL ')).Count
    $ok = ($LASTEXITCODE -eq 0 -and $fail -eq 0)
    '{0,-22} {1,3} passed, {2} failed  {3}' -f $check, $pass, $fail, $(if ($ok) { 'OK' } else { 'FAILED' })
    if (-not $ok) { $failed += $check; $output }
}
if ($failed.Count -gt 0) { throw "Failed: $($failed -join ', ')" }
'All checks passed.'
