#requires -Version 5.1
<#
.SYNOPSIS
    Builds the measure program AVDTune.Bench.exe (.NET 10, self-contained single file, x64, ReadyToRun) and runs its unit tests.
    The binary is never committed: the release workflow builds it and puts its SHA256 into the release manifest.
.PARAMETER Output   Folder for the published file (default: Bench\out, ignored by git).
.PARAMETER SkipTests  Do not run the unit tests first.
.NOTES
    Runs from the Bench folder (Push-Location), so global.json (exact SDK, no roll forward), nuget.config (nuget.org only) and the lock files apply whatever the caller's folder is.
    The lock files pin the packages; they do not pin the runtime pack or Crossgen2 that publish downloads. The SHA256 in the release manifest secures the result, not the build.
#>
[CmdletBinding()]
param([string]$Output, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
if (-not $Output) { $Output = Join-Path $PSScriptRoot 'out' }
$Output = [IO.Path]::GetFullPath($Output)   # relative to the caller's folder, before the change of folder below
Push-Location $PSScriptRoot
try {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw 'The .NET SDK is not installed (dotnet not found). Install the .NET 10 SDK.' }
    $want = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
    $sdk = ([string](& dotnet --version)).Trim()
    if ($sdk -ne $want) { throw "global.json pins the .NET SDK $want but dotnet --version says $sdk. Install $want (the pin is not followed)." }

    # The packages are the ones of the lock files (packages.lock.json): a changed package fails the restore (issue #19).
    foreach ($proj in 'AVDTune.Bench.csproj', 'tests\AVDTune.Bench.Tests\AVDTune.Bench.Tests.csproj') {
        & dotnet restore (Join-Path $PSScriptRoot $proj) --locked-mode -nologo
        if ($LASTEXITCODE -ne 0) { throw "dotnet restore (locked mode) failed for $proj (packages.lock.json out of date?)." }
    }

    if (-not $SkipTests) {
        Push-Location (Join-Path $PSScriptRoot 'tests\AVDTune.Bench.Tests')
        try {
            & dotnet run -c Release -nologo --no-restore
            if ($LASTEXITCODE -ne 0) { throw 'The unit tests of the measure program failed.' }
        }
        finally { Pop-Location }
    }

    & dotnet publish (Join-Path $PSScriptRoot 'AVDTune.Bench.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishReadyToRun=true -o $Output -nologo --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }
    $exe = Join-Path $Output 'AVDTune.Bench.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Not built: $exe" }
    # the release holds the exe and nothing next to it: AVDTune refuses to start it when Bench\bin has any other file (no DLL to side-load)
    $others = @(Get-ChildItem -LiteralPath $Output -Force | Where-Object { $_.Name -ne 'AVDTune.Bench.exe' } | ForEach-Object Name)
    if ($others.Count -gt 0) { throw "The publish folder has more than the exe ($($others -join ', ')). A release carries the single file only." }
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    '{0}  {1:N1} MB  SHA256 {2}' -f $exe, ((Get-Item -LiteralPath $exe).Length / 1MB), $hash
}
finally { Pop-Location }