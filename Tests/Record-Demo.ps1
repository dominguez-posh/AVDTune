#requires -Version 5.1
<#
.SYNOPSIS
    Records the animated tour of the README (docs\screenshots\demo.webp) and the screenshots next to it from the GUI smoke test.
.DESCRIPTION
    Runs Tests\Invoke-GuiSmoke.ps1 (off-screen window, fake machine, fake sign-in and fake Azure, a temporary state folder: no tenant, no real VM, nothing of
    this computer is changed) unless -SmokeDir names the output of a smoke run that is already there. Takes the screenshots named in $Tour (the same size each;
    a frame of another size is put on a canvas of the first one), copies them to docs\screenshots and makes the animated WebP with img2webp from libwebp
    (winget install Google.Libwebp). Without img2webp the PNGs are copied and the script says what is missing.
    The pictures show demo data only (example names: GM-TEST01, rg-example, admin.example). Check them by hand before a commit: Check-PublicContent.ps1 does
    not read images.
.EXAMPLE
    .\Tests\Record-Demo.ps1
.EXAMPLE
    .\Tests\Record-Demo.ps1 -SmokeDir $env:TEMP\AVDTuneSmoke-AVDTune
#>
[CmdletBinding()]
param([string]$SmokeDir, [string]$OutDir, [ValidateRange(500, 10000)][int]$FrameMs = 2600, [ValidateRange(1, 100)][int]$Quality = 60)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force   # Remove-AVDTuneTreeSafe for the temporary frames (no link followed)
if (-not $OutDir) { $OutDir = Join-Path $repo 'docs\screenshots' }
# The tour: screenshot of the smoke test (no shot with a toast or text that shows a path of this computer, e.g. 35b-benchmark-compare, 50-protocol-export-snapshots) (shot-<name>.png) and the name it gets in docs\screenshots. Only pictures that show demo data, no paths of this computer.
$Tour = @(
    @('01-overview-light', 'overview.png'),
    @('20-start-snapshot-ready', 'snapshot-gate.png'),
    @('30-updates-list', 'updates.png'),
    @('32-vdi-host-cards', 'vdi.png'),
    @('03-overview-dark', 'overview-dark.png')
)
if (-not $SmokeDir) {
    $SmokeDir = Join-Path ([IO.Path]::GetTempPath()) 'AVDTuneSmoke-demo'
    & (Join-Path $PSScriptRoot 'Invoke-GuiSmoke.ps1') -OutDir $SmokeDir
}
$missing = @($Tour | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SmokeDir "shot-$($_[0]).png")) } | ForEach-Object { $_[0] })
if ($missing.Count) { throw "The smoke run in $SmokeDir has no screenshot $($missing -join ', '). Run Tests\Invoke-GuiSmoke.ps1 first (it must pass)." }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# frames of one size: the first screenshot sets the canvas
Add-Type -AssemblyName System.Drawing
$frames = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-demo-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $frames | Out-Null
try {
    $size = $null; $list = @()
    foreach ($t in $Tour) {
        $src = Join-Path $SmokeDir "shot-$($t[0]).png"
        Copy-Item -LiteralPath $src -Destination (Join-Path $OutDir $t[1]) -Force
        $img = [Drawing.Image]::FromFile($src)
        try {
            if (-not $size) { $size = $img.Size }
            $canvas = New-Object Drawing.Bitmap($size.Width, $size.Height)
            $g = [Drawing.Graphics]::FromImage($canvas)
            try { $g.Clear([Drawing.Color]::White); $g.DrawImage($img, 0, 0, [Math]::Min($img.Width, $size.Width), [Math]::Min($img.Height, $size.Height)) } finally { $g.Dispose() }
            $f = Join-Path $frames ('{0:00}.png' -f $list.Count); $canvas.Save($f, [Drawing.Imaging.ImageFormat]::Png); $canvas.Dispose(); $list += $f
        }
        finally { $img.Dispose() }
    }
    # img2webp: from PATH, else where winget puts libwebp
    $tool = $null
    $cmd = Get-Command img2webp.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $tool = $cmd.Source }
    else { $tool = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter img2webp.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $tool) { "Screenshots copied to $OutDir. img2webp was not found (winget install Google.Libwebp): demo.webp was not made."; return }
    $out = Join-Path $OutDir 'demo.webp'
    $wargs = @('-loop', '0', '-lossy', '-q', [string]$Quality, '-d', [string]$FrameMs) + $list + @('-o', $out)
    # img2webp writes its summary to stderr: not an error here, the exit code decides
    $ErrorActionPreference = 'Continue'
    & $tool @wargs 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "img2webp failed (exit code $LASTEXITCODE)." }
    "Tour: $($list.Count) frames of $($size.Width)x$($size.Height), $([Math]::Round($list.Count * $FrameMs / 1000, 1)) s -> $out ($([Math]::Round((Get-Item $out).Length / 1KB)) KB)"
}
finally { if (Test-Path -LiteralPath $frames) { [void](Remove-AVDTuneTreeSafe -Path $frames) } }
