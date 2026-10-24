# Pester 5 tests. Run from the repo root:  Invoke-Pester -Path tests
# The image pipeline runs with a nearest-neighbour 4x stand-in for the AI engine. 'Engine runs' uses the real engine
# on the CPU with a tiny test model, and is skipped until the engine runtime is installed; no GPU is needed.

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
        $scripts = Get-ChildItem -LiteralPath $AppDir -File -Recurse | Where-Object { @('.ps1', '.psm1', '.cs', '.xaml') -contains $_.Extension }
        @($scripts).Count | Should -Be 7
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
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        # Stands in for the runtime ZIP: pinned names with test contents, whose hashes stand in for the real pins.
        function New-TestArchive([string]$Path, [hashtable]$Entries) {
            $archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            foreach ($name in $Entries.Keys) {
                $writer = New-Object System.IO.StreamWriter ($archive.CreateEntry($name).Open())
                $writer.Write($Entries[$name])
                $writer.Dispose()
            }
            $archive.Dispose()
        }
        function Get-TextHash([string]$Text) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
        }
        function Expand-WithPins([string]$Zip, [string]$Out, [hashtable]$Pins) {
            InModuleScope HOOPICS.Core -Parameters @{ Zip = $Zip; Out = $Out; Pins = $Pins } {
                $saved = $script:Runtime
                $script:Runtime = [pscustomobject]@{ Files = $Pins }
                try { Expand-EngineArchive -Path $Zip -Destination $Out } finally { $script:Runtime = $saved }
            }
        }
        $Pins = @{ 'onnxruntime.dll' = (Get-TextHash 'ort'); 'DirectML.dll' = (Get-TextHash 'dml') }
    }

    It 'unpacks only the pinned DLLs and the license texts' {
        $zip = Join-Path $TestDrive 'runtime.zip'
        New-TestArchive $zip @{ 'onnxruntime.dll' = 'ort'; 'DirectML.dll' = 'dml'; 'licenses/DirectML-LICENSE.txt' = 'terms'
            'tool.exe' = 'x'; 'extra.dll' = 'x'; '../escape.dll' = 'x'; 'licenses/../../escape.txt' = 'x'; 'nested/onnxruntime.dll' = 'x' }
        $out = Join-Path $TestDrive 'runtime'
        Expand-WithPins $zip $out $Pins
        $files = Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object { $_.FullName.Substring($out.Length + 1) }
        $files | Sort-Object | Should -Be @('DirectML.dll', 'licenses\DirectML-LICENSE.txt', 'onnxruntime.dll')
        Test-Path -LiteralPath (Join-Path $TestDrive 'escape.dll') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'escape.txt') | Should -BeFalse
    }

    It 'rejects a DLL that does not match its pinned hash' {
        $zip = Join-Path $TestDrive 'swapped.zip'
        New-TestArchive $zip @{ 'onnxruntime.dll' = 'ort'; 'DirectML.dll' = 'not the real one' }
        { Expand-WithPins $zip (Join-Path $TestDrive 'swapped') $Pins } | Should -Throw 'HOOPICS:Checksum:DirectML.dll*'
    }

    It 'rejects a runtime with a DLL missing' {
        $zip = Join-Path $TestDrive 'short.zip'
        New-TestArchive $zip @{ 'onnxruntime.dll' = 'ort' }
        { Expand-WithPins $zip (Join-Path $TestDrive 'short') $Pins } | Should -Throw 'HOOPICS:Checksum:DirectML.dll is missing*'
    }

    It 'rejects a download whose checksum does not match' {
        $file = Join-Path $TestDrive 'tampered.zip'
        Set-Content -LiteralPath $file -Value 'tampered'
        { InModuleScope HOOPICS.Core -Parameters @{ File = $file } { Assert-FileHash $File $script:Runtime.Sha256 } } | Should -Throw 'HOOPICS:Checksum*'
    }

    It 'pins every DLL that the engine loads' {
        $pinned = InModuleScope HOOPICS.Core { @($script:Runtime.Files.Keys) }
        foreach ($name in 'onnxruntime.dll', 'DirectML.dll', 'Microsoft.ML.OnnxRuntime.dll', 'System.Memory.dll', 'System.Buffers.dll',
            'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll', 'msvcp140.dll', 'msvcp140_1.dll',
            'vcruntime140.dll', 'vcruntime140_1.dll') {
            $pinned | Should -Contain $name
        }
    }

    It 'treats an empty engine folder as not installed' {
        $saved = $env:HOOPICS_ENGINE_DIR, $env:HOOPICS_RUNTIME_DIR
        $env:HOOPICS_ENGINE_DIR = Join-Path $TestDrive 'nothing-here'
        $env:HOOPICS_RUNTIME_DIR = $null
        try { Test-HoopicsEngine | Should -BeFalse } finally { $env:HOOPICS_ENGINE_DIR, $env:HOOPICS_RUNTIME_DIR = $saved }
    }

    It 'treats a runtime with a changed DLL as not installed' {
        $dir = Join-Path $TestDrive 'changed-runtime'
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($name in (InModuleScope HOOPICS.Core { @($script:Runtime.Files.Keys) })) { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $saved = $env:HOOPICS_RUNTIME_DIR
        $env:HOOPICS_RUNTIME_DIR = $dir
        try { Test-HoopicsEngine | Should -BeFalse } finally { $env:HOOPICS_RUNTIME_DIR = $saved }
    }

    It 'works in a private ASCII-only folder' {
        $dir = InModuleScope HOOPICS.Core { New-WorkDirectory }
        try {
            $dir | Should -Match '^[\x20-\x7E]+$'
            InModuleScope HOOPICS.Core -Parameters @{ Dir = $dir } { Test-PrivateDirectory $Dir } | Should -BeTrue -Because 'it holds the pictures'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }

    It 'does not take a folder that other users can open for a private one' {
        $dir = Join-Path $TestDrive 'shared'
        New-Item -ItemType Directory -Path $dir | Out-Null
        InModuleScope HOOPICS.Core -Parameters @{ Dir = $dir } { Test-PrivateDirectory $Dir } | Should -BeFalse
    }

    It 'starts when the temp folder name is outside the ANSI code page' {
        # A Hangul user name on an English Windows; on a Korean Windows the name is ANSI and this passes trivially.
        $temp = Join-Path $TestDrive ((-join [char[]](0xD64D, 0xAE38, 0xB3D9)) + ' temp')
        New-Item -ItemType Directory -Path $temp | Out-Null
        $command = @"
`$ErrorActionPreference = 'Stop'
`$env:TEMP = `$env:TMP = '$temp'
try {
    Import-Module '$(Join-Path $AppDir 'HOOPICS.Core.psm1')'
    Add-Type -TypeDefinition 'public static class HoopicsTempProbe { public static int Two() { return 2; } }'
    'temp: ' + [IO.Path]::GetTempPath()
    'work: ' + (& (Get-Module HOOPICS.Core) { `$dir = New-WorkDirectory; Remove-Item -LiteralPath `$dir -Recurse -Force; `$dir })
} catch {
    'error: ' + `$_.Exception.ToString()
    exit 1
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $ErrorActionPreference = 'Continue'
        $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 0 -Because ($log -join "`n")
        $log | Where-Object { $_ -like 'temp: *' } | Should -Match '^temp: [\x20-\x7E]+$'
        $log | Where-Object { $_ -like 'work: *' } | Should -Match '^work: [\x20-\x7E]+$'
    }
}

# The real engine on the CPU, with a tiny hand-made model (tests\fixtures\blur-x4: a 3x3 blur, then 4x nearest
# neighbour). It needs the engine runtime: install it with Install-HoopicsEngine, or point HOOPICS_RUNTIME_DIR at it.
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\HOOPICS.Core.psm1') -Force
    $RuntimeReady = Test-HoopicsEngine
}

Describe 'Engine runs' -Skip:(-not $RuntimeReady) {
    BeforeAll {
        $Fixtures = Join-Path $PSScriptRoot 'fixtures'
        $EngineScript = Join-Path $AppDir 'engine\hoopics-engine.ps1'
        $Runtime = InModuleScope HOOPICS.Core { Get-RuntimeDirectory }
        # The core's model names, backed by the test model.
        $ModelDir = Join-Path $TestDrive 'models'
        New-Item -ItemType Directory -Path $ModelDir | Out-Null
        foreach ($precision in 'fp32', 'fp16') {
            Copy-Item (Join-Path $Fixtures "blur-x4.$precision.onnx") (Join-Path $ModelDir "realesr-animevideov3-x4.$precision.onnx")
        }
        $SavedEnvironment = @{}
        foreach ($name in 'HOOPICS_MODEL_DIR', 'HOOPICS_ENGINE_DEVICE', 'HOOPICS_ENGINE_DIR', 'HOOPICS_RUNTIME_DIR') {
            $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:HOOPICS_MODEL_DIR = $ModelDir
        $env:HOOPICS_ENGINE_DEVICE = 'cpu'
        $env:HOOPICS_ENGINE_DIR = Join-Path $TestDrive 'engine'
        $env:HOOPICS_RUNTIME_DIR = $Runtime

        # Gray, with a red square and a blue bar; small tile settings cut it into many tiles.
        $Picture = Join-Path $TestDrive 'picture.png'
        New-TestImage $Picture 90 70 {
            param($g)
            $g.Clear([System.Drawing.Color]::Gray)
            $g.FillRectangle([System.Drawing.Brushes]::Red, 10, 10, 30, 30)
            $g.FillRectangle([System.Drawing.Brushes]::Blue, 50, 40, 35, 12)
        }

        # One picture through hoopics-engine.ps1 directly, so a test can pick the tile size or inject a fault.
        function Invoke-EngineScript([string]$In, [string]$Out, [string[]]$Arguments, [string]$Fault) {
            $env:HOOPICS_ENGINE_FAULT = $Fault
            $ErrorActionPreference = 'Continue'
            try {
                $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EngineScript -r $Runtime -i $In -o $Out `
                    -m (Join-Path $Fixtures 'blur-x4') -g cpu @Arguments 2>&1 | ForEach-Object { "$_" }
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Log = @($log) }
            } finally {
                Remove-Item Env:\HOOPICS_ENGINE_FAULT -ErrorAction SilentlyContinue
            }
        }

        function Get-Pixels([string]$Path) {
            $bitmap = New-Object System.Drawing.Bitmap $Path
            try {
                $rect = New-Object System.Drawing.Rectangle 0, 0, $bitmap.Width, $bitmap.Height
                $data = $bitmap.LockBits($rect, 'ReadOnly', 'Format32bppArgb')
                $bytes = New-Object byte[] ($data.Stride * $data.Height)
                [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
                $bitmap.UnlockBits($data)
                , $bytes
            } finally {
                $bitmap.Dispose()
            }
        }

        function Test-SamePixels([string]$A, [string]$B) {
            [Linq.Enumerable]::SequenceEqual([byte[]](Get-Pixels $A), [byte[]](Get-Pixels $B))
        }

        $Whole = Join-Path $TestDrive 'whole.png'
        $WholeRun = Invoke-EngineScript $Picture $Whole @('-t', '512', '-x', '2')
    }

    AfterAll {
        InModuleScope HOOPICS.Core { Stop-HoopicsEngine }
        foreach ($name in $SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $SavedEnvironment[$name]) }
    }

    It 'enlarges a picture 4x on the CPU' {
        $WholeRun.ExitCode | Should -Be 0 -Because ($WholeRun.Log -join "`n")
        Get-Size $Whole | Should -Be '360x280'
        $WholeRun.Log | Should -Contain '100.00%'
        # Inside the square the blur changes nothing; each pixel becomes a 4x4 block.
        $inside = Get-Pixel $Whole 100 100
        '{0},{1},{2}' -f $inside.R, $inside.G, $inside.B | Should -Be '255,0,0'
        (Get-Pixel $Whole 300 20).R | Should -Be 128
        # The picture's edge is repeated outward, so the blur keeps the gray corner gray; zeros would darken it.
        (Get-Pixel $Whole 0 0).R | Should -Be 128
    }

    It 'gives exactly the same picture in tiles as in one piece' {
        $tiled = Join-Path $TestDrive 'tiled.png'
        $run = Invoke-EngineScript $Picture $tiled @('-t', '16', '-x', '2')
        $run.ExitCode | Should -Be 0 -Because ($run.Log -join "`n")
        Test-SamePixels $Whole $tiled | Should -BeTrue
    }

    It 'enlarges transparency too' {
        $in = Join-Path $TestDrive 'alpha-in.png'
        New-TestImage $in 40 40 { param($g) $g.Clear([System.Drawing.Color]::Transparent); $g.FillEllipse([System.Drawing.Brushes]::Blue, 10, 10, 20, 20) } -Alpha
        $out = Join-Path $TestDrive 'alpha-out.png'
        (Invoke-EngineScript $in $out @()).ExitCode | Should -Be 0
        Get-Size $out | Should -Be '160x160'
        (Get-Pixel $out 2 2).A | Should -Be 0
        (Get-Pixel $out 80 80).A | Should -Be 255
    }

    It 'still finishes the picture when the device fails (<Fault>)' -ForEach @(
        @{ Fault = 'lost@3'; Tile = '16'; Says = '[[]fallback[]]*' }
        @{ Fault = 'garbage@2'; Tile = '16'; Says = '[[]fallback[]]*' }
        @{ Fault = 'garbage@0'; Tile = '128'; Says = '[[]retry[]]*' }
        @{ Fault = 'oom@0'; Tile = '128'; Says = '[[]retry[]]*' }
    ) {
        $out = Join-Path $TestDrive "fault-$($Fault.Split('@')[0]).png"
        $run = Invoke-EngineScript $Picture $out @('-t', $Tile, '-x', '2') $Fault
        $run.ExitCode | Should -Be 0 -Because ($run.Log -join "`n")
        @($run.Log | Where-Object { $_ -like $Says }).Count | Should -BeGreaterThan 0 -Because ($run.Log -join "`n")
        Test-SamePixels $Whole $out | Should -BeTrue
    }

    It 'reports a model that does not exist' {
        $run = Invoke-EngineScript $Picture (Join-Path $TestDrive 'none.png') @('-m', (Join-Path $TestDrive 'no-such-model'))
        $run.ExitCode | Should -Be 4
    }

    It 'keeps one engine for several jobs and survives a failed one' {
        $state = @{ Percent = 0; CancelRequested = $false; Process = $null; Note = $null }
        $first = Join-Path $TestDrive 'job1.png'
        InModuleScope HOOPICS.Core -Parameters @{ In = $Picture; Out = $first; State = $state } {
            Invoke-Engine -InputFile $In -OutputFile $Out -Model 'anime' -State $State
        }
        $state.Percent | Should -Be 100
        $state.Note | Should -Be 'cpu'
        $engine = InModuleScope HOOPICS.Core { $script:EngineProcess.Id }

        { InModuleScope HOOPICS.Core -Parameters @{ In = (Join-Path $TestDrive 'missing.png'); Out = (Join-Path $TestDrive 'job2.png') } {
                Invoke-Engine -InputFile $In -OutputFile $Out -Model 'anime'
            } } | Should -Throw 'HOOPICS:Engine:exit code 5*'

        $third = Join-Path $TestDrive 'job3.png'
        InModuleScope HOOPICS.Core -Parameters @{ In = $Picture; Out = $third } { Invoke-Engine -InputFile $In -OutputFile $Out -Model 'anime' }
        InModuleScope HOOPICS.Core { $script:EngineProcess.Id } | Should -Be $engine
        Test-SamePixels $Whole $third | Should -BeTrue
    }

    It 'passes folder names in Korean to the engine' {
        $folder = Join-Path $TestDrive (-join [char[]](0xD55C, 0xAE00))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $models = Join-Path $folder 'models'
        Copy-Item -LiteralPath $ModelDir -Destination $models -Recurse
        $env:HOOPICS_MODEL_DIR = $models
        try {
            $out = Join-Path $TestDrive 'korean.png'
            InModuleScope HOOPICS.Core -Parameters @{ In = $Picture; Out = $out } { Invoke-Engine -InputFile $In -OutputFile $Out -Model 'anime' }
            Get-Size $out | Should -Be '360x280'
        } finally {
            $env:HOOPICS_MODEL_DIR = $ModelDir
        }
    }

    It 'reports a runtime that cannot load' {
        InModuleScope HOOPICS.Core { Stop-HoopicsEngine }
        $env:HOOPICS_RUNTIME_DIR = Join-Path $TestDrive 'no-runtime'
        try {
            { InModuleScope HOOPICS.Core -Parameters @{ In = $Picture; Out = (Join-Path $TestDrive 'no-runtime.png') } {
                    Invoke-Engine -InputFile $In -OutputFile $Out -Model 'anime'
                } } | Should -Throw 'HOOPICS:Runtime:*'
        } finally {
            $env:HOOPICS_RUNTIME_DIR = $Runtime
        }
    }

    It 'enlarges a picture end to end with the real engine' {
        $file = Join-Path $TestDrive 'end-to-end.png'
        New-TestImage $file 120 80
        $result = Invoke-HoopicsImage -Path $file -Target @(@{ Width = 400; Height = 300 })
        Get-Size $result.Path | Should -Be '400x300'
        InModuleScope HOOPICS.Core { $script:EngineProcess } | Should -Not -BeNullOrEmpty -Because 'the real engine did the work'
        InModuleScope HOOPICS.Core { Stop-HoopicsEngine }
    }

    It 'works when the temp folder name is outside the ANSI code page' {
        # A Hangul user name on an English Windows; on a Korean Windows the name is ANSI and this passes trivially.
        $temp = Join-Path $TestDrive ((-join [char[]](0xD64D, 0xAE38, 0xB3D9)) + ' temp')
        New-Item -ItemType Directory -Path $temp | Out-Null
        $out = Join-Path $TestDrive 'ansi-temp'
        New-Item -ItemType Directory -Path $out | Out-Null
        $command = @"
`$ErrorActionPreference = 'Stop'
`$env:TEMP = `$env:TMP = '$temp'
try {
    Import-Module '$(Join-Path $AppDir 'HOOPICS.Core.psm1')'
    (Invoke-HoopicsImage -Path '$Picture' -Target @(@{ Scale = 2 }) -OutDir '$out').Path
} catch {
    'error: ' + `$_.Exception.ToString()
    `$odd = Get-ChildItem Env: | Where-Object { `$_.Value -match '[^\x20-\x7E]' } | ForEach-Object { `$_.Name + '=' + `$_.Value }
    'current folder: ' + [Environment]::CurrentDirectory + '; TEMP: ' + `$env:TEMP + '; non-ASCII variables: ' + (`$odd -join ', ')
    exit 1
} finally {
    if (Get-Command Stop-HoopicsEngine -ErrorAction SilentlyContinue) { Stop-HoopicsEngine }
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $ErrorActionPreference = 'Continue'
        $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 0 -Because ($log -join "`n")
        Get-Size (Join-Path $out 'picture_x2.png') | Should -Be '180x140'
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
