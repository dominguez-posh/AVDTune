#requires -Version 5.1
<#
.SYNOPSIS
    Builds the measure program AVDTune.Bench.exe (.NET 10, self-contained single file, x64, ReadyToRun) and runs its unit tests.
    The binary is never committed: the release workflow builds it and puts its SHA256 into the release manifest.
.PARAMETER Output   Folder for the published file (default: Bench\out, ignored by git).
.PARAMETER SkipTests  Do not run the unit tests first.
#>
[CmdletBinding()]
param([string]$Output, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
if (-not $Output) { $Output = Join-Path $PSScriptRoot 'out' }
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'The .NET SDK is not installed (dotnet not found). Install the .NET 10 SDK.' }
$sdk = (& dotnet --version)
if ([version]($sdk -replace '-.*$', '') -lt [version]'10.0') { throw "The .NET 10 SDK is needed (found $sdk)." }

if (-not $SkipTests) {
    Push-Location (Join-Path $PSScriptRoot 'tests\AVDTune.Bench.Tests')
    try {
        & dotnet run -c Release -nologo
        if ($LASTEXITCODE -ne 0) { throw 'The unit tests of the measure program failed.' }
    }
    finally { Pop-Location }
}

& dotnet publish (Join-Path $PSScriptRoot 'AVDTune.Bench.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishReadyToRun=true -o $Output -nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }
$exe = Join-Path $Output 'AVDTune.Bench.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Not built: $exe" }
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
'{0}  {1:N1} MB  SHA256 {2}' -f $exe, ((Get-Item -LiteralPath $exe).Length / 1MB), $hash
