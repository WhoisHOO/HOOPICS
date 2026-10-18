# Pester 5 tests. Run from the repo root:  Invoke-Pester -Path tests
# The AI engine is replaced by a nearest-neighbour 4x stand-in, so no GPU or download is needed.

BeforeAll {
    $AppDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
    Import-Module (Join-Path $AppDir 'HOOPICS.Core.psm1') -Force
    Add-Type -AssemblyName System.Drawing

    function New-TestImage([string]$Path, [int]$Width, [int]$Height, [scriptblock]$Paint, [switch]$Alpha, [string]$Format = 'Png') {
        $pixelFormat = if ($Alpha) { 'Format32bppArgb' } else { 'Format24bppRgb' }
        $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::$pixelFormat)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            if ($Paint) { & $Paint $graphics } else { $graphics.Clear([System.Drawing.Color]::Gray) }
        } finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::$Format)
        $bitmap.Dispose()
    }

    function Get-Pixel([string]$Path, [int]$X, [int]$Y) {
        $bitmap = New-Object System.Drawing.Bitmap $Path
        try { $bitmap.GetPixel($X, $Y) } finally { $bitmap.Dispose() }
    }

    function Get-Size([string]$Path) {
        $image = [System.Drawing.Image]::FromFile($Path)
        try { '{0}x{1}' -f $image.Width, $image.Height } finally { $image.Dispose() }
    }
}

Describe 'Presets and models' {
    It 'offers several sizes for every device type' {
        foreach ($category in 'laptop', 'monitor', 'phone') {
            @(Get-HoopicsPreset -Category $category).Count | Should -BeGreaterThan 3
        }
    }

    It 'has phone and tablet sizes in portrait' {
        foreach ($preset in Get-HoopicsPreset -Category phone) { $preset.Height | Should -BeGreaterThan $preset.Width }
    }

    It 'lists the three models' {
        Get-HoopicsModel | Should -Be @('anime', 'anime-sharp', 'photo')
    }
}

Describe 'Translations' {
    BeforeAll {
        $strings = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $AppDir 'strings.json') | ConvertFrom-Json
        $window = Get-Content -Raw -LiteralPath (Join-Path $AppDir 'HOOPICS.ps1')
        $core = Get-Content -Raw -LiteralPath (Join-Path $AppDir 'HOOPICS.Core.psm1')
    }

    It 'has the same keys in Korean and English' {
        $ko = $strings.ko.PSObject.Properties.Name | Sort-Object
        $en = $strings.en.PSObject.Properties.Name | Sort-Object
        $ko | Should -Be $en
    }

    It 'has every key the window asks for' {
        $keys = [regex]::Matches($window, "(?:Get-Text|Format-Text) '(\w+)'") | ForEach-Object { $_.Groups[1].Value }
        $listed = [regex]::Matches($window, "foreach \(\`$key in ([^)]+)\)") |
            ForEach-Object { [regex]::Matches($_.Groups[1].Value, "'(\w+)'") } | ForEach-Object { $_.Groups[1].Value }
        foreach ($key in @($keys) + @($listed) + 'Fatal') {
            $strings.ko.$key | Should -Not -BeNullOrEmpty -Because "strings.json needs '$key'"
        }
    }

    It 'explains every error the core can raise' {
        $codes = [regex]::Matches($core, "New-HoopicsError '(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($code in $codes) {
            $strings.ko."Err_$code" | Should -Not -BeNullOrEmpty -Because "strings.json needs 'Err_$code'"
        }
    }

    It 'keeps the scripts ASCII so Windows PowerShell 5.1 reads them in any code page' {
        $scripts = Get-ChildItem -LiteralPath $AppDir -File | Where-Object { @('.ps1', '.psm1', '.cs', '.xaml') -contains $_.Extension }
        @($scripts).Count | Should -Be 5
        foreach ($file in $scripts) {
            [IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty -Because $file.Name
        }
    }
}

Describe 'Window layout' {
    It 'loads, and defines every control the script uses' {
        Add-Type -AssemblyName PresentationFramework
        [xml]$xaml = Get-Content -Raw -LiteralPath (Join-Path $AppDir 'MainWindow.xaml')
        $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
        $script = Get-Content -Raw -LiteralPath (Join-Path $AppDir 'HOOPICS.ps1')
        $used = [regex]::Matches($script, '\$ui\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($name in $used) { $window.FindName($name) | Should -Not -BeNullOrEmpty -Because "HOOPICS.ps1 uses `$ui.$name" }
    }
}

Describe 'Planning' {
    It 'needs one AI pass to fill a 2560x1600 laptop from a 1178x661 frame' {
        $plan = Get-HoopicsPlan -SourceWidth 1178 -SourceHeight 661 -Target @(@{ Width = 2560; Height = 1600 })
        [Math]::Round($plan.Scale, 3) | Should -Be 2.421
        $plan.Passes | Should -Be 1
    }

    It 'takes the largest need across several screens' {
        $plan = Get-HoopicsPlan -SourceWidth 1178 -SourceHeight 661 -Target @(@{ Width = 1920; Height = 1080 }, @{ Width = 2560; Height = 1600 })
        $plan.Sizes.Count | Should -Be 2
        [Math]::Round($plan.Scale, 3) | Should -Be 2.421
    }

    It 'needs no AI when fitting into a smaller shape' {
        (Get-HoopicsPlan -SourceWidth 1178 -SourceHeight 661 -Target @(@{ Width = 1080; Height = 2400 }) -Mode fit).Passes | Should -Be 0
    }

    It 'chains two passes beyond 4x and refuses beyond 16x' {
        (Get-HoopicsPlan -SourceWidth 600 -SourceHeight 400 -Target @(@{ Width = 3840; Height = 2160 })).Passes | Should -Be 2
        (Get-HoopicsPlan -SourceWidth 100 -SourceHeight 100 -Target @(@{ Width = 3840; Height = 2160 })).TooSmall | Should -BeTrue
    }

    It 'keeps the shape for a scale factor' {
        $plan = Get-HoopicsPlan -SourceWidth 1178 -SourceHeight 661 -Target @(@{ Scale = 2 })
        '{0}x{1}' -f $plan.Sizes[0].Width, $plan.Sizes[0].Height | Should -Be '2356x1322'
    }
}

Describe 'Image pipeline' {
    BeforeAll {
        Mock -ModuleName HOOPICS.Core Invoke-Engine {
            $source = [System.Drawing.Image]::FromFile($InputFile)
            try {
                $output = New-Object System.Drawing.Bitmap -ArgumentList ($source.Width * 4), ($source.Height * 4), $source.PixelFormat
                $graphics = [System.Drawing.Graphics]::FromImage($output)
                $graphics.InterpolationMode = 'NearestNeighbor'
                $graphics.PixelOffsetMode = 'Half'
                $graphics.DrawImage($source, (New-Object System.Drawing.Rectangle 0, 0, $output.Width, $output.Height))
                $graphics.Dispose()
                $output.Save($OutputFile, [System.Drawing.Imaging.ImageFormat]::Png)
                $output.Dispose()
            } finally {
                $source.Dispose()
            }
        }
        $Stripes = {
            param($g)
            $g.Clear([System.Drawing.Color]::Red)
            $g.FillRectangle([System.Drawing.Brushes]::Lime, 100, 0, 200, 100)
            $g.FillRectangle([System.Drawing.Brushes]::Blue, 300, 0, 100, 100)
        }
    }

    It 'fills a screen size exactly, cropping evenly from both sides' {
        $file = Join-Path $TestDrive 'stripes.png'
        New-TestImage $file 400 100 $Stripes
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Width = 200; Height = 200 })
        Split-Path -Leaf $result.Path | Should -Be 'stripes_200x200.png'
        Get-Size $result.Path | Should -Be '200x200'
        # Only the green middle survives a centred crop of a 4:1 picture into a square.
        (Get-Pixel $result.Path 3 100).G | Should -BeGreaterThan 200
        (Get-Pixel $result.Path 196 100).G | Should -BeGreaterThan 200
        Should -Invoke Invoke-Engine -ModuleName HOOPICS.Core -Times 1 -Exactly
    }

    It 'fits the whole picture over a dimmed copy of itself' {
        $file = Join-Path $TestDrive 'fit.png'
        New-TestImage $file 400 100 { param($g) $g.Clear([System.Drawing.Color]::Lime) }
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Width = 800; Height = 800 }) -Mode fit
        $inside = Get-Pixel $result.Path 400 400
        $border = Get-Pixel $result.Path 400 40
        $inside.G | Should -BeGreaterThan 240
        $border.G | Should -BeLessThan 180
    }

    It 'enlarges by a factor and names the file after it' {
        $file = Join-Path $TestDrive 'factor.png'
        New-TestImage $file 300 200
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2.5 })
        Split-Path -Leaf $result.Path | Should -Be 'factor_x2.5.png'
        Get-Size $result.Path | Should -Be '750x500'
    }

    It 'chains two engine passes for big enlargements' {
        $file = Join-Path $TestDrive 'tiny.png'
        New-TestImage $file 60 40
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Width = 600; Height = 400 })
        Get-Size $result.Path | Should -Be '600x400'
        Should -Invoke Invoke-Engine -ModuleName HOOPICS.Core -Times 2 -Exactly
    }

    It 'returns one result per target and reuses identical sizes' {
        $file = Join-Path $TestDrive 'twins.png'
        New-TestImage $file 320 180
        $results = @(Invoke-HoopicsImage -Path $file -Target @(@{ Width = 640; Height = 360 }, @{ Width = 1280; Height = 720 }, @{ Width = 640; Height = 360 }))
        $results.Count | Should -Be 3
        $results[0].Path | Should -Be $results[2].Path
        Get-Size $results[1].Path | Should -Be '1280x720'
    }

    It 'keeps transparency in PNG and flattens it onto white in JPG' {
        $file = Join-Path $TestDrive 'alpha.png'
        New-TestImage $file 100 100 { param($g) $g.Clear([System.Drawing.Color]::Transparent); $g.FillEllipse([System.Drawing.Brushes]::Blue, 25, 25, 50, 50) } -Alpha
        $png = Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 })
        (Get-Pixel $png.Path 2 2).A | Should -Be 0
        (Get-Pixel $png.Path 100 100).A | Should -Be 255
        $jpg = Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 }) -Format jpg
        (Get-Pixel $jpg.Path 2 2).R | Should -BeGreaterThan 245
    }

    It 'never overwrites an earlier result' {
        $file = Join-Path $TestDrive 'again.png'
        New-TestImage $file 100 100
        $first = Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 })
        $second = Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 })
        Split-Path -Leaf $second.Path | Should -Be 'again_x2 (2).png'
        Test-Path -LiteralPath $first.Path | Should -BeTrue
    }

    It 'reads from and writes to folders with Korean names' {
        $korean = -join [char[]](0xD55C, 0xAE00, 0x0020, 0xD3F4, 0xB354)
        $folder = Join-Path $TestDrive $korean
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file = Join-Path $folder ((-join [char[]](0xC0AC, 0xC9C4)) + '.png')
        New-TestImage $file 100 100
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Width = 300; Height = 300 })
        Split-Path -Parent $result.Path | Should -Be $folder
        Get-Size $result.Path | Should -Be '300x300'
    }

    It 'turns photos that were stored sideways' {
        $file = Join-Path $TestDrive 'sideways.jpg'
        $bitmap = New-Object System.Drawing.Bitmap 300, 200
        $orientation = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
        $orientation.Id = 0x0112
        $orientation.Type = 3
        $orientation.Len = 2
        $orientation.Value = [BitConverter]::GetBytes([uint16]6)
        $bitmap.SetPropertyItem($orientation)
        $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bitmap.Dispose()

        $info = Get-HoopicsImageInfo $file
        '{0}x{1}' -f $info.Width, $info.Height | Should -Be '200x300'
        $info.Orientation | Should -Be 6
        Get-Size (Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 })).Path | Should -Be '400x600'
    }

    It 'refuses pictures that would need more than 16x' {
        $file = Join-Path $TestDrive 'speck.png'
        New-TestImage $file 20 20
        { Invoke-HoopicsImage -Path $file -Target @(@{ Width = 3840; Height = 2160 }) } | Should -Throw 'HOOPICS:TooSmall*'
    }

    It 'reports files that are not images' {
        $file = Join-Path $TestDrive 'fake.jpg'
        Set-Content -LiteralPath $file -Value 'not an image'
        { Invoke-HoopicsImage -Path $file -Target @(@{ Scale = 2 }) } | Should -Throw 'HOOPICS:Decode*'
    }
}

Describe 'Engine install' {
    It 'unpacks only the engine, its DLLs and the models' {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = Join-Path $TestDrive 'engine.zip'
        $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
        foreach ($name in 'realesrgan-ncnn-vulkan.exe', 'vcomp140.dll', 'models/realesrgan-x4plus.param',
            'input.jpg', 'onepiece_demo.mp4', '../escape.dll', 'nested/tool.exe') {
            $writer = New-Object System.IO.StreamWriter ($archive.CreateEntry($name).Open())
            $writer.Write('x')
            $writer.Dispose()
        }
        $archive.Dispose()
        $out = Join-Path $TestDrive 'engine'

        InModuleScope HOOPICS.Core -Parameters @{ Zip = $zip; Out = $out } { Expand-EngineArchive -Path $Zip -Destination $Out }

        $files = Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object { $_.FullName.Substring($out.Length + 1) }
        $files | Sort-Object | Should -Be @('models\realesrgan-x4plus.param', 'realesrgan-ncnn-vulkan.exe', 'vcomp140.dll')
        Test-Path -LiteralPath (Join-Path $TestDrive 'escape.dll') | Should -BeFalse
    }

    It 'rejects a download whose checksum does not match' {
        $file = Join-Path $TestDrive 'tampered.zip'
        Set-Content -LiteralPath $file -Value 'tampered'
        { InModuleScope HOOPICS.Core -Parameters @{ File = $file } { Assert-EngineArchive -Path $File } } | Should -Throw 'HOOPICS:Checksum*'
    }

    It 'treats an empty engine folder as not installed' {
        $env:HOOPICS_ENGINE_DIR = Join-Path $TestDrive 'nothing-here'
        try { Test-HoopicsEngine | Should -BeFalse } finally { Remove-Item Env:\HOOPICS_ENGINE_DIR }
    }

    It 'works in an ASCII-only folder, which the engine needs' {
        $dir = InModuleScope HOOPICS.Core { New-WorkDirectory }
        try { $dir | Should -Match '^[\x20-\x7E]+$' } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Engine runs' {
    BeforeAll {
        # A stand-in exe that prints what the real engine prints on stderr; the model name (-n) picks the outcome.
        $engineDir = Join-Path $TestDrive 'fake-engine'
        New-Item -ItemType Directory -Path $engineDir | Out-Null
        Add-Type -OutputType ConsoleApplication -OutputAssembly (Join-Path $engineDir 'realesrgan-ncnn-vulkan.exe') -TypeDefinition @'
using System;
using System.IO;

public static class FakeEngine {
    public static int Main(string[] args) {
        string output = null, model = null;
        for (int i = 0; i + 1 < args.Length; i++) {
            if (args[i] == "-o") output = args[i + 1];
            if (args[i] == "-n") model = args[i + 1];
        }
        Console.Error.WriteLine("[0 Fake GPU]  queueC=2[8]  queueG=0[16]  queueT=1[2]");
        Console.Error.WriteLine("50.00%");
        if (model == "gpu-error") Console.Error.WriteLine("vkQueueSubmit failed -4");
        if (model == "no-output") { Console.Error.WriteLine("decode image pass0.png failed"); return 0; }
        Console.Error.WriteLine("100.00%");
        File.WriteAllBytes(output, new byte[] { 0 });
        return 0;
    }
}
'@
        $env:HOOPICS_ENGINE_DIR = $engineDir
    }

    AfterAll {
        Remove-Item Env:\HOOPICS_ENGINE_DIR -ErrorAction SilentlyContinue
    }

    It 'follows the progress of a clean run' {
        $state = @{ Percent = 0; CancelRequested = $false; Process = $null }
        $out = Join-Path $TestDrive 'clean.png'
        InModuleScope HOOPICS.Core -Parameters @{ Out = $out; State = $state } {
            Invoke-Engine -InputFile 'pass0.png' -OutputFile $Out -Model 'ok' -State $State
        }
        Test-Path -LiteralPath $out | Should -BeTrue
        $state.Percent | Should -Be 100
    }

    It 'fails when the GPU reports an error, although the engine exits 0 and writes an image' {
        $out = Join-Path $TestDrive 'gpu.png'
        { InModuleScope HOOPICS.Core -Parameters @{ Out = $out } { Invoke-Engine -InputFile 'pass0.png' -OutputFile $Out -Model 'gpu-error' } } |
            Should -Throw 'HOOPICS:Gpu:vkQueueSubmit failed -4'
    }

    It 'fails when the engine writes no image' {
        $out = Join-Path $TestDrive 'none.png'
        { InModuleScope HOOPICS.Core -Parameters @{ Out = $out } { Invoke-Engine -InputFile 'pass0.png' -OutputFile $Out -Model 'no-output' } } |
            Should -Throw 'HOOPICS:Engine:*decode image pass0.png failed*'
    }
}

Describe 'Screens' -Skip:(-not $env:HOOPICS_DESKTOP_TESTS) {
    It 'reports every connected screen in real pixels' {
        $monitors = @(Get-HoopicsMonitor)
        $monitors.Count | Should -BeGreaterThan 0
        @($monitors | Where-Object Primary).Count | Should -Be 1
        foreach ($monitor in $monitors) { $monitor.Width | Should -BeGreaterThan 0 }
    }
}
