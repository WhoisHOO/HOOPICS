# HOOPICS core: engine install, presets, monitor detection and the image pipeline.
# Shared by the window (HOOPICS.ps1) and the command line (hoopics-cli.ps1).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.

Add-Type -AssemblyName System.Drawing
if (-not ('Hoopics.Desktop' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs')
}

$script:Version = '0.1.0'
$script:AppRoot = Split-Path -Parent $PSScriptRoot

# Pinned upstream release; the download is rejected unless it matches this SHA-256.
$script:Engine = [pscustomobject]@{
    Name   = 'realesrgan-ncnn-vulkan-20220424'
    Url    = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip'
    Sha256 = 'ABC02804E17982A3BE33675E4D471E91EA374E65B70167ABC09E31ACB412802D'
    Exe    = 'realesrgan-ncnn-vulkan.exe'
}

# Every model runs at its native 4x and the result is resampled to the exact target size.
# On anime frames this came out cleaner than the engine's own 2x/3x models (fewer halos).
$script:Models = [ordered]@{
    'anime'       = 'realesr-animevideov3'
    'anime-sharp' = 'realesrgan-x4plus-anime'
    'photo'       = 'realesrgan-x4plus'
}

$script:InputExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif', '.tif', '.tiff')

function New-Preset([string]$Category, [string]$Label, [string]$Ratio, [int]$Width, [int]$Height) {
    [pscustomobject]@{ Category = $Category; Label = $Label; Ratio = $Ratio; Width = $Width; Height = $Height }
}

$script:Presets = @(
    New-Preset 'laptop' 'HD' '16:9' 1366 768
    New-Preset 'laptop' 'FHD' '16:9' 1920 1080
    New-Preset 'laptop' 'WUXGA' '16:10' 1920 1200
    New-Preset 'laptop' 'QHD+' '16:10' 2560 1600
    New-Preset 'laptop' '2.8K' '16:10' 2880 1800
    New-Preset 'laptop' '3K' '3:2' 3000 2000
    New-Preset 'laptop' '4K UHD' '16:9' 3840 2160
    New-Preset 'laptop' 'MacBook Air 13"' '' 2560 1664
    New-Preset 'laptop' 'MacBook Air 15"' '' 2880 1864
    New-Preset 'laptop' 'MacBook Pro 14"' '' 3024 1964
    New-Preset 'laptop' 'MacBook Pro 16"' '' 3456 2234
    New-Preset 'monitor' 'FHD' '16:9' 1920 1080
    New-Preset 'monitor' 'WUXGA' '16:10' 1920 1200
    New-Preset 'monitor' 'QHD' '16:9' 2560 1440
    New-Preset 'monitor' 'WQXGA' '16:10' 2560 1600
    New-Preset 'monitor' '4K UHD' '16:9' 3840 2160
    New-Preset 'monitor' '5K' '16:9' 5120 2880
    New-Preset 'monitor' 'Ultrawide FHD' '21:9' 2560 1080
    New-Preset 'monitor' 'Ultrawide QHD' '21:9' 3440 1440
    New-Preset 'monitor' 'Super ultrawide' '32:9' 5120 1440
    New-Preset 'phone' 'Android FHD+' '20:9' 1080 2400
    New-Preset 'phone' 'Android QHD+' '20:9' 1440 3200
    New-Preset 'phone' 'Galaxy S' '19.5:9' 1080 2340
    New-Preset 'phone' 'Galaxy S Ultra' '19.5:9' 1440 3120
    New-Preset 'phone' 'iPhone' '19.5:9' 1179 2556
    New-Preset 'phone' 'iPhone Pro Max' '19.5:9' 1290 2796
    New-Preset 'phone' 'iPad 11"' '' 1640 2360
    New-Preset 'phone' 'iPad Pro 13"' '' 2064 2752
)

# Errors meant for people are thrown as 'HOOPICS:<Code>:<detail>'; the window localizes <Code>.
function New-HoopicsError([string]$Code, [string]$Detail = '') {
    New-Object System.Exception ("HOOPICS:{0}:{1}" -f $Code, $Detail)
}

function Get-HoopicsVersion { $script:Version }

function Get-HoopicsModel { @($script:Models.Keys) }

function Get-HoopicsInputExtension { $script:InputExtensions }

function Get-HoopicsPreset {
    param([string]$Category)
    if ($Category) { $script:Presets | Where-Object Category -EQ $Category } else { $script:Presets }
}

#region Monitors

function Get-MonitorDescription {
    # WMI instance 'DISPLAY\DELF18C\4&2a..&UID4145_0' matches device path '\\?\DISPLAY#DELF18C#4&2a..&UID4145#{...}'.
    $result = @{}
    try {
        $technology = @{}
        Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop |
            ForEach-Object { $technology[$_.InstanceName] = [int64]$_.VideoOutputTechnology }
        foreach ($monitor in Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop) {
            $key = ($monitor.InstanceName -replace '_\d+$', '').Replace('\', '#')
            $name = (-join ($monitor.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })).Trim()
            # LVDS, embedded DisplayPort, embedded UDI and "internal" are built-in laptop panels.
            $internal = @(6, 11, 13, 2147483648) -contains $technology[$monitor.InstanceName]
            $result[$key] = [pscustomobject]@{ Name = $name; Internal = $internal }
        }
    } catch {
        # Names are cosmetic; the window falls back to "Monitor N".
    }
    $result
}

function Get-HoopicsMonitor {
    $descriptions = Get-MonitorDescription
    $number = 0
    [Hoopics.Desktop]::GetMonitors() |
        Sort-Object @{ Expression = { if ($_.Left -eq 0 -and $_.Top -eq 0) { 0 } else { 1 } } }, Left, Top |
        ForEach-Object {
            $number++
            $id = $_.Id
            $match = $descriptions.Keys | Where-Object { $id.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
            $description = if ($match) { $descriptions[$match] } else { [pscustomobject]@{ Name = ''; Internal = $false } }
            [pscustomobject]@{
                Number   = $number
                Id       = $id
                Width    = $_.Width
                Height   = $_.Height
                Left     = $_.Left
                Top      = $_.Top
                Primary  = ($_.Left -eq 0 -and $_.Top -eq 0)
                Name     = $description.Name
                Internal = [bool]$description.Internal
            }
        }
}

function Set-HoopicsWallpaper {
    param(
        [Parameter(Mandatory)] [string] $MonitorId,
        [Parameter(Mandatory)] [string] $Path
    )
    [Hoopics.Desktop]::SetWallpaper($MonitorId, (Resolve-Path -LiteralPath $Path).ProviderPath)
}

#endregion

#region Engine

function Get-EngineDirectory {
    if ($env:HOOPICS_ENGINE_DIR) { return $env:HOOPICS_ENGINE_DIR }
    Join-Path (Join-Path $script:AppRoot 'engine') $script:Engine.Name
}

function Get-EngineModelFiles([string]$Model) {
    # The engine picks realesr-animevideov3-x4.* itself from "-s 4"; the x4plus models have no suffix.
    $base = if ($Model -eq 'realesr-animevideov3') { "$Model-x4" } else { $Model }
    "$base.param", "$base.bin"
}

function Test-HoopicsEngine {
    $dir = Get-EngineDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $dir $script:Engine.Exe))) { return $false }
    foreach ($model in $script:Models.Values) {
        foreach ($file in Get-EngineModelFiles $model) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $dir 'models') $file))) { return $false }
        }
    }
    $true
}

function Set-Progress($State, [string]$Activity, [double]$Percent) {
    if ($State) {
        $State.Percent = $Percent
    } else {
        Write-Progress -Activity 'HOOPICS' -Status $Activity -PercentComplete ([int][Math]::Min(100, [Math]::Max(0, $Percent)))
    }
}

function Save-EngineArchive([string]$Destination, $State) {
    # GitHub needs TLS 1.2, which Windows PowerShell 5.1 does not always enable by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $request = [Net.HttpWebRequest]::Create($script:Engine.Url)
        $request.UserAgent = "HOOPICS/$script:Version"
        $response = $request.GetResponse()
    } catch {
        throw (New-HoopicsError 'Download' $_.Exception.Message)
    }
    try {
        $total = $response.ContentLength
        $in = $response.GetResponseStream()
        $out = [IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 262144
            $done = 0L
            while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($State -and $State.CancelRequested) { throw (New-HoopicsError 'Canceled') }
                $out.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) { Set-Progress $State 'Downloading the AI engine' (100.0 * $done / $total) }
            }
        } catch [Net.WebException], [IO.IOException] {
            throw (New-HoopicsError 'Download' $_.Exception.Message)
        } finally {
            $out.Dispose()
            $in.Dispose()
        }
    } finally {
        $response.Close()
    }
}

function Assert-EngineArchive([string]$Path) {
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -ne $script:Engine.Sha256) {
        throw (New-HoopicsError 'Checksum' "expected $($script:Engine.Sha256), got $hash")
    }
}

function Expand-EngineArchive([string]$Path, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            # Only the engine, its runtime DLLs and the models; the pattern cannot climb out of $Destination.
            $name = $entry.FullName.Replace('\', '/')
            if ($name -notmatch '^(?:models/)?[A-Za-z0-9._-]+\.(?:exe|dll|param|bin)$') { continue }
            $target = Join-Path $Destination $name.Replace('/', '\')
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
}

function Install-HoopicsEngine {
    param($State)
    $target = Get-EngineDirectory
    if (Test-HoopicsEngine) { return $target }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $zip = Join-Path $parent "$($script:Engine.Name).zip.part"
    $staging = "$target.staging"
    try {
        Save-EngineArchive -Destination $zip -State $State
        Assert-EngineArchive -Path $zip
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        Expand-EngineArchive -Path $zip -Destination $staging
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $target)
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $target
}

function Invoke-Engine {
    param(
        [string] $InputFile,
        [string] $OutputFile,
        [string] $Model,
        $State,
        [double] $ProgressBase = 0,
        [double] $ProgressSpan = 100
    )
    $dir = Get-EngineDirectory
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $dir $script:Engine.Exe
    $start.Arguments = '-i "{0}" -o "{1}" -n {2} -s 4 -m "{3}"' -f $InputFile, $OutputFile, $Model, (Join-Path $dir 'models')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardOutput = $true
    $process = [Diagnostics.Process]::Start($start)
    if ($State) { $State.Process = $process }
    $log = New-Object Collections.Generic.List[string]
    try {
        # stderr carries "12.50%" progress lines; stdout stays empty.
        while ($null -ne ($line = $process.StandardError.ReadLine())) {
            if ($line -match '^(\d+(?:\.\d+)?)%$') {
                Set-Progress $State 'Upscaling' ($ProgressBase + $ProgressSpan * [double]$Matches[1] / 100)
            } elseif ($line.Trim()) {
                $log.Add($line)
            }
        }
        [void]$process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
    } finally {
        if ($State) { $State.Process = $null }
    }
    if ($State -and $State.CancelRequested) { throw (New-HoopicsError 'Canceled') }
    # After a GPU error (e.g. "vkQueueSubmit failed -4" when the driver resets the GPU) the engine still
    # exits 0 and writes an image that is partly or wholly black, so any such line fails the pass.
    $gpuError = $log | Where-Object { $_ -match '\bvk\w+ failed' } | Select-Object -First 1
    if ($gpuError) { throw (New-HoopicsError 'Gpu' $gpuError) }
    # The engine exits 0 even when it cannot decode its input, so the output file is the real check.
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputFile)) {
        $detail = ($log | Where-Object { $_ -notmatch '^\[\d+ ' } | Select-Object -Last 3) -join ' / '
        throw (New-HoopicsError 'Engine' ("exit code {0}. {1}" -f $process.ExitCode, $detail))
    }
}

#endregion

#region Planning

function Get-RequiredScale([int]$SourceWidth, [int]$SourceHeight, [int]$Width, [int]$Height, [string]$Mode) {
    $sx = $Width / $SourceWidth
    $sy = $Height / $SourceHeight
    if ($Mode -eq 'fit') { [Math]::Min($sx, $sy) } else { [Math]::Max($sx, $sy) }
}

function Get-PassCount([double]$Scale) {
    if ($Scale -le 1) { return 0 }
    if ($Scale -le 4) { return 1 }
    if ($Scale -le 16) { return 2 }
    throw (New-HoopicsError 'TooSmall' ('needs {0:0.0}x' -f $Scale))
}

function Resolve-TargetSize([int]$SourceWidth, [int]$SourceHeight, [object[]]$Target) {
    foreach ($t in $Target) {
        if ($t.Scale) {
            [pscustomobject]@{
                Width  = [Math]::Max(1, [int][Math]::Round($SourceWidth * $t.Scale))
                Height = [Math]::Max(1, [int][Math]::Round($SourceHeight * $t.Scale))
                Scale  = [double]$t.Scale
            }
        } else {
            [pscustomobject]@{ Width = [int]$t.Width; Height = [int]$t.Height; Scale = $null }
        }
    }
}

function Get-HoopicsPlan {
    param(
        [Parameter(Mandatory)] [int] $SourceWidth,
        [Parameter(Mandatory)] [int] $SourceHeight,
        [Parameter(Mandatory)] [object[]] $Target,
        [ValidateSet('fill', 'fit')] [string] $Mode = 'fill'
    )
    $sizes = @(Resolve-TargetSize $SourceWidth $SourceHeight $Target)
    $need = ($sizes | ForEach-Object {
            if ($null -ne $_.Scale) { $_.Scale } else { Get-RequiredScale $SourceWidth $SourceHeight $_.Width $_.Height $Mode }
        } | Measure-Object -Maximum).Maximum
    try { $passes = Get-PassCount $need } catch { $passes = -1 }
    [pscustomobject]@{ Sizes = $sizes; Scale = $need; Passes = $passes; TooSmall = ($passes -lt 0) }
}

#endregion

#region Images

function Copy-Bitmap($Image, [bool]$Alpha) {
    $format = if ($Alpha) { [Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [Drawing.Imaging.PixelFormat]::Format24bppRgb }
    $copy = New-Object Drawing.Bitmap -ArgumentList $Image.Width, $Image.Height, $format
    $graphics = [Drawing.Graphics]::FromImage($copy)
    try {
        $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.DrawImage($Image, (New-Object Drawing.Rectangle 0, 0, $Image.Width, $Image.Height))
    } finally {
        $graphics.Dispose()
    }
    $copy
}

function Get-ExifOrientation($Image) {
    if ($Image.PropertyIdList -contains 0x0112) {
        return [int][BitConverter]::ToUInt16($Image.GetPropertyItem(0x0112).Value, 0)
    }
    1
}

function Open-ImageWithWic([string]$Path) {
    # Formats GDI+ cannot read (WebP, ...) go through the Windows Imaging Component codecs instead.
    Add-Type -AssemblyName PresentationCore, WindowsBase
    $stream = [IO.File]::OpenRead($Path)
    try {
        $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($stream,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($decoder.Frames[0]))
        $png = New-Object IO.MemoryStream
        $encoder.Save($png)
        $png.Position = 0
        [Drawing.Image]::FromStream($png)
    } finally {
        $stream.Dispose()
    }
}

function Read-HoopicsImage([string]$Path) {
    $image = $null
    try { $image = [Drawing.Image]::FromFile($Path) } catch { $image = $null }
    if (-not $image) {
        try { $image = Open-ImageWithWic $Path } catch { throw (New-HoopicsError 'Decode' $Path) }
    }
    try {
        $alpha = [Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat) -or
            (($image.Flags -band [int][Drawing.Imaging.ImageFlags]::HasAlpha) -ne 0)
        $bitmap = Copy-Bitmap $image $alpha
        $flip = switch (Get-ExifOrientation $image) {
            2 { 'RotateNoneFlipX' } 3 { 'Rotate180FlipNone' } 4 { 'Rotate180FlipX' } 5 { 'Rotate90FlipX' }
            6 { 'Rotate90FlipNone' } 7 { 'Rotate270FlipX' } 8 { 'Rotate270FlipNone' } default { $null }
        }
        if ($flip) { $bitmap.RotateFlip([Drawing.RotateFlipType]::$flip) }
        [pscustomobject]@{ Bitmap = $bitmap; HasAlpha = $alpha }
    } finally {
        $image.Dispose()
    }
}

function Get-HoopicsImageInfo([string]$Path) {
    # Header-only read. Width and Height are as displayed, i.e. swapped for photos stored sideways.
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $image = [Drawing.Image]::FromStream($stream, $false, $false)
        try {
            $orientation = Get-ExifOrientation $image
            $width, $height = $image.Width, $image.Height
            if ($orientation -ge 5) { $width, $height = $height, $width }
            return [pscustomobject]@{ Width = $width; Height = $height; Orientation = $orientation }
        } finally {
            $image.Dispose()
        }
    } catch {
        # Fall through to WIC below.
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    try {
        $image = Open-ImageWithWic $Path
        try { return [pscustomobject]@{ Width = $image.Width; Height = $image.Height; Orientation = 1 } } finally { $image.Dispose() }
    } catch {
        return $null
    }
}

function New-Canvas([int]$Width, [int]$Height, [bool]$Alpha) {
    $format = if ($Alpha) { [Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [Drawing.Imaging.PixelFormat]::Format24bppRgb }
    New-Object Drawing.Bitmap -ArgumentList $Width, $Height, $format
}

function New-Painter($Bitmap) {
    $graphics = [Drawing.Graphics]::FromImage($Bitmap)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics
}

function New-DrawAttributes([double]$Brightness = 1.0) {
    $attributes = New-Object Drawing.Imaging.ImageAttributes
    # Mirrored edges stop the bicubic filter from pulling in a dark border.
    $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
    if ($Brightness -ne 1.0) {
        $matrix = New-Object Drawing.Imaging.ColorMatrix
        $matrix.Matrix00 = [single]$Brightness
        $matrix.Matrix11 = [single]$Brightness
        $matrix.Matrix22 = [single]$Brightness
        $attributes.SetColorMatrix($matrix)
    }
    $attributes
}

function Copy-ImageRegion($Canvas, $Image, [int]$X, [int]$Y, [int]$Width, [int]$Height,
    [double]$SourceX, [double]$SourceY, [double]$SourceWidth, [double]$SourceHeight, [double]$Brightness = 1.0) {
    $graphics = New-Painter $Canvas
    $attributes = New-DrawAttributes $Brightness
    try {
        $graphics.DrawImage($Image, (New-Object Drawing.Rectangle $X, $Y, $Width, $Height),
            [single]$SourceX, [single]$SourceY, [single]$SourceWidth, [single]$SourceHeight,
            [Drawing.GraphicsUnit]::Pixel, $attributes)
    } finally {
        $attributes.Dispose()
        $graphics.Dispose()
    }
}

function Resize-ToFill($Image, [int]$Width, [int]$Height, [bool]$Alpha) {
    # Cover the whole canvas and crop the overflow evenly, like the Windows "Fill" wallpaper style.
    $scale = [Math]::Max($Width / $Image.Width, $Height / $Image.Height)
    $sourceWidth = $Width / $scale
    $sourceHeight = $Height / $scale
    $canvas = New-Canvas $Width $Height $Alpha
    Copy-ImageRegion $canvas $Image 0 0 $Width $Height (($Image.Width - $sourceWidth) / 2) (($Image.Height - $sourceHeight) / 2) $sourceWidth $sourceHeight
    $canvas
}

function Resize-ToFit($Image, [int]$Width, [int]$Height, [bool]$Alpha) {
    # Whole picture centred; the spare space shows the same picture blurred and dimmed.
    # The blur is the picture shrunk to a few dozen pixels and stretched back up.
    $tiny = Resize-ToFill $Image ([Math]::Max(4, [int]($Width / 40))) ([Math]::Max(4, [int]($Height / 40))) $Alpha
    $canvas = New-Canvas $Width $Height $Alpha
    try {
        Copy-ImageRegion $canvas $tiny 0 0 $Width $Height 0 0 $tiny.Width $tiny.Height 0.55
    } finally {
        $tiny.Dispose()
    }
    $scale = [Math]::Min($Width / $Image.Width, $Height / $Image.Height)
    $w = [Math]::Max(1, [int][Math]::Round($Image.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($Image.Height * $scale))
    Copy-ImageRegion $canvas $Image ([int](($Width - $w) / 2)) ([int](($Height - $h) / 2)) $w $h 0 0 $Image.Width $Image.Height
    $canvas
}

function Resize-ToSize($Image, [int]$Width, [int]$Height, [bool]$Alpha) {
    $canvas = New-Canvas $Width $Height $Alpha
    Copy-ImageRegion $canvas $Image 0 0 $Width $Height 0 0 $Image.Width $Image.Height
    $canvas
}

function Save-HoopicsImage($Bitmap, [string]$Path, [string]$Format, [bool]$Alpha) {
    # Write next to the destination first so a failure never leaves half a file behind.
    $temp = "$Path.part"
    $flat = $null
    try {
        if ($Format -eq 'jpg') {
            $toSave = $Bitmap
            if ($Alpha) {
                $flat = New-Canvas $Bitmap.Width $Bitmap.Height $false
                $graphics = [Drawing.Graphics]::FromImage($flat)
                try {
                    $graphics.Clear([Drawing.Color]::White)
                    $graphics.DrawImage($Bitmap, (New-Object Drawing.Rectangle 0, 0, $Bitmap.Width, $Bitmap.Height))
                } finally {
                    $graphics.Dispose()
                }
                $toSave = $flat
            }
            $codec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.FormatID -eq [Drawing.Imaging.ImageFormat]::Jpeg.Guid }
            $parameters = New-Object Drawing.Imaging.EncoderParameters 1
            $parameters.Param[0] = New-Object Drawing.Imaging.EncoderParameter -ArgumentList ([Drawing.Imaging.Encoder]::Quality), ([long]95)
            $toSave.Save($temp, $codec, $parameters)
        } else {
            $Bitmap.Save($temp, [Drawing.Imaging.ImageFormat]::Png)
        }
        [IO.File]::Move($temp, $Path)   # literal paths; Get-UniquePath made sure $Path is free
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw (New-HoopicsError 'Save' ("{0}: {1}" -f $Path, $_.Exception.Message))
    } finally {
        if ($flat) { $flat.Dispose() }
    }
}

function Get-UniquePath([string]$Directory, [string]$Name, [string]$Extension) {
    $candidate = Join-Path $Directory "$Name.$Extension"
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Directory "$Name ($n).$Extension"
        $n++
    }
    $candidate
}

function Test-WritableDirectory([string]$Directory) {
    try {
        if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Directory ('.hoopics-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        $true
    } catch {
        $false
    }
}

function Resolve-OutputDirectory([string]$Requested, [string]$InputPath) {
    $directory = if ($Requested) { $Requested } else { Split-Path -Parent $InputPath }
    if (Test-WritableDirectory $directory) { return $directory }
    $fallback = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'HOOPICS'
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    $fallback
}

function Get-ShortPath([string]$Path) {
    try { (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Path).ShortPath } catch { $null }
}

function New-WorkDirectory {
    # The engine crashes when its output path has non-ASCII characters (e.g. a Korean user name
    # inside %TEMP%), so the work folder must be ASCII-only.
    $temp = [IO.Path]::GetTempPath()
    $candidates = @($temp, (Get-ShortPath $temp), (Join-Path $env:ProgramData 'HOOPICS'), (Join-Path $env:PUBLIC 'HOOPICS'))
    foreach ($base in $candidates) {
        if (-not $base -or $base -notmatch '^[\x20-\x7E]+$') { continue }
        $dir = Join-Path $base ('hoopics-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        try {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            return $dir
        } catch {
            continue
        }
    }
    throw (New-HoopicsError 'WorkDir')
}

function Invoke-HoopicsImage {
    <#
    .SYNOPSIS
        Upscales one image and writes one file per target size. Returns @{ Path; Width; Height } per target, in order.
    .PARAMETER Target
        Objects with Width and Height (a preset, a monitor, @{Width=..;Height=..}) or with Scale (@{Scale=2}).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Target,
        [ValidateSet('anime', 'anime-sharp', 'photo')] [string] $Model = 'anime',
        [ValidateSet('fill', 'fit')] [string] $Mode = 'fill',
        [ValidateSet('png', 'jpg')] [string] $Format = 'png',
        [string] $OutDir,
        $State
    )
    $source = Read-HoopicsImage $Path
    $upscaled = $null
    $work = $null
    try {
        Set-Progress $State 'Preparing' 5
        $plan = Get-HoopicsPlan -SourceWidth $source.Bitmap.Width -SourceHeight $source.Bitmap.Height -Target $Target -Mode $Mode
        if ($plan.TooSmall) { throw (New-HoopicsError 'TooSmall' ('needs {0:0.0}x' -f $plan.Scale)) }

        $image = $source.Bitmap
        if ($plan.Passes -gt 0) {
            $work = New-WorkDirectory
            $current = Join-Path $work 'pass0.png'
            $source.Bitmap.Save($current, [Drawing.Imaging.ImageFormat]::Png)
            for ($pass = 1; $pass -le $plan.Passes; $pass++) {
                $next = Join-Path $work "pass$pass.png"
                $span = 80 / $plan.Passes
                Invoke-Engine -InputFile $current -OutputFile $next -Model $script:Models[$Model] -State $State `
                    -ProgressBase (10 + $span * ($pass - 1)) -ProgressSpan $span
                $current = $next
            }
            $upscaled = Read-HoopicsImage $current
            $image = $upscaled.Bitmap
        }

        Set-Progress $State 'Saving' 92
        $directory = Resolve-OutputDirectory $OutDir $Path
        $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
        $written = @{}
        foreach ($size in $plan.Sizes) {
            $key = '{0}x{1}' -f $size.Width, $size.Height
            if (-not $written.ContainsKey($key)) {
                $suffix = if ($null -ne $size.Scale) {
                    '_x' + $size.Scale.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
                } else {
                    "_$key"
                }
                $canvas = if ($null -ne $size.Scale) {
                    Resize-ToSize $image $size.Width $size.Height $source.HasAlpha
                } elseif ($Mode -eq 'fit') {
                    Resize-ToFit $image $size.Width $size.Height $source.HasAlpha
                } else {
                    Resize-ToFill $image $size.Width $size.Height $source.HasAlpha
                }
                try {
                    $file = Get-UniquePath $directory ($stem + $suffix) $Format
                    Save-HoopicsImage $canvas $file $Format $source.HasAlpha
                } finally {
                    $canvas.Dispose()
                }
                $written[$key] = $file
            }
            [pscustomobject]@{ Path = $written[$key]; Width = $size.Width; Height = $size.Height }
        }
        Set-Progress $State 'Done' 100
    } finally {
        $source.Bitmap.Dispose()
        if ($upscaled) { $upscaled.Bitmap.Dispose() }
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $State) { Write-Progress -Activity 'HOOPICS' -Completed }
        [GC]::Collect()
    }
}

#endregion

Export-ModuleMember -Function Get-HoopicsVersion, Get-HoopicsModel, Get-HoopicsInputExtension, Get-HoopicsPreset,
    Get-HoopicsMonitor, Set-HoopicsWallpaper, Test-HoopicsEngine, Install-HoopicsEngine, Get-HoopicsPlan,
    Get-HoopicsImageInfo, Invoke-HoopicsImage
