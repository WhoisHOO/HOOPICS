<#
.SYNOPSIS
    HOOPICS from the command line: the same engine and pipeline as the window.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 photo.jpg -Size 2560x1600
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 art.png -Screens -SetWallpaper
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File app\hoopics-cli.ps1 C:\pics\*.jpg -Scale 2 -Model photo -Format jpg
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Path,
    # One or more WxH sizes, e.g. 2560x1600,1920x1080.
    [string[]] $Size,
    # Enlarge by a factor (1.01 - 16) and keep the shape.
    [double] $Scale,
    # One output per connected screen, at its real resolution.
    [switch] $Screens,
    # With -Screens and a single input: also set each result as that screen's background.
    [switch] $SetWallpaper,
    [ValidateSet('anime', 'anime-sharp', 'photo')] [string] $Model = 'anime',
    [ValidateSet('fill', 'fit')] [string] $Mode = 'fill',
    [ValidateSet('png', 'jpg')] [string] $Format = 'png',
    # Defaults to the folder of each input image.
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HOOPICS.Core.psm1') -Force

try {
    $chosen = @(($Size.Count -gt 0), ($Scale -gt 0), $Screens.IsPresent) | Where-Object { $_ }
    if (-not $Path -or @($chosen).Count -ne 1) {
        throw 'Give one or more images and exactly one of -Size WxH, -Scale N or -Screens. See Get-Help for examples.'
    }

    $files = foreach ($pattern in $Path) {
        # Try it as a wildcard first; names with [brackets] only match literally.
        $items = @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)
        if (-not $items -and (Test-Path -LiteralPath $pattern -PathType Leaf)) { $items = @(Get-Item -LiteralPath $pattern) }
        $found = @($items | Where-Object { -not $_.PSIsContainer })
        # Get-Item -LiteralPath returns nothing, without an error, for a missing path with brackets.
        if (-not $found) { throw "No image found at '$pattern'." }
        $found.FullName
    }

    $monitors = $null
    if ($Screens) {
        $monitors = @(Get-HoopicsMonitor)
        if (-not $monitors) { throw 'No screens detected; use -Size instead.' }
        $targets = $monitors
    } elseif ($Scale) {
        if ($Scale -le 1 -or $Scale -gt 16) { throw '-Scale must be between 1.01 and 16.' }
        $targets = @(@{ Scale = $Scale })
    } else {
        $targets = foreach ($entry in $Size) {
            if ($entry -notmatch '^\s*(\d+)\s*[xX*]\s*(\d+)\s*$') { throw "Size '$entry' is not WxH, e.g. 2560x1600." }
            @{ Width = [int]$Matches[1]; Height = [int]$Matches[2] }
        }
    }
    if ($SetWallpaper -and (-not $Screens -or @($files).Count -ne 1)) {
        throw '-SetWallpaper needs -Screens and exactly one input image.'
    }

    if (-not (Test-HoopicsEngine)) {
        Write-Host 'Downloading the AI engine (first run only, about 16 MB)...'
        [void](Install-HoopicsEngine)
    }

    foreach ($file in $files) {
        $results = @(Invoke-HoopicsImage -Path $file -Target $targets -Model $Model -Mode $Mode -Format $Format -OutDir $OutDir)
        foreach ($result in $results | Sort-Object Path -Unique) {
            Write-Host ('{0} -> {1} ({2}x{3})' -f (Split-Path -Leaf $file), $result.Path, $result.Width, $result.Height)
        }
        if ($SetWallpaper) {
            for ($i = 0; $i -lt $monitors.Count; $i++) { Set-HoopicsWallpaper -MonitorId $monitors[$i].Id -Path $results[$i].Path }
            Write-Host 'Desktop background updated.'
        }
    }
} catch {
    Write-Host "hoopics: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-HoopicsEngine
}
