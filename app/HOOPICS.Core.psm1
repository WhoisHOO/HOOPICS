# HOOPICS core: engine install, presets, monitor detection and the image pipeline.
# Shared by the window (HOOPICS.ps1) and the command line (hoopics-cli.ps1).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.

Add-Type -AssemblyName System.Drawing

function Get-ShortPath([string]$Path) {
    try { (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Path).ShortPath } catch { $null }
}

function Test-AsciiPath([string]$Path) {
    # Without '?': a short-path lookup that finds no 8.3 name can hand back the name with '?' for each letter.
    $Path -match '^[\x20-\x7E]+$' -and $Path -notmatch '[?*]'
}

# The private folders are open only to this user, SYSTEM and Administrators.
$script:PrivateSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')

function New-PrivateDirectory([string]$Path) {
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in $script:PrivateSids) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (
                    (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # The folders above it keep their usual permissions, so other users can add their own.
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [void][IO.Directory]::CreateDirectory($Path, $security)
}

function Test-PrivateDirectory([string]$Path) {
    # Another user could have made the folder first, to read or swap what goes in it.
    $acl = [IO.Directory]::GetAccessControl($Path)
    if ($script:PrivateSids -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($script:PrivateSids -notcontains $rule.IdentityReference.Value) { return $false }
    }
    $true
}

# Add-Type compiles with csc.exe, which cannot use a temp folder whose name has letters outside the ANSI code page,
# such as a Hangul user name on an English Windows: CodeDom creates its folders there with ANSI calls, on some PCs
# (seen elevated, on a build server) even from the long form of an 8.3 short name. Then use a private folder in
# ProgramData, or the short name as a last resort. The engine, a child process, inherits the setting.
# The private folder holds the code Add-Type compiles and loads, so it sits right in ProgramData, where other users
# may not delete or rename it, and is checked each time in case someone else made it first.
if (-not (Test-AsciiPath ([IO.Path]::GetTempPath()))) {
    $privateTemp = Join-Path $env:ProgramData "HOOPICS-temp-$($script:PrivateSids[0])"
    foreach ($dir in $privateTemp, (Get-ShortPath ([IO.Path]::GetTempPath()))) {
        if (-not $dir -or -not (Test-AsciiPath $dir)) { continue }
        try {
            if ($dir -eq $privateTemp) {
                if (-not [IO.Directory]::Exists($dir)) { New-PrivateDirectory $dir }
                if (-not (Test-PrivateDirectory $dir)) { continue }
            }
            $probe = Join-Path $dir ('.hoopics-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, '')
            [IO.File]::Delete($probe)
            $env:TEMP = $dir
            $env:TMP = $dir
            break
        } catch {
            continue
        }
    }
}

if (-not ('Hoopics.Desktop' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs')
}

$script:Version = '0.2.0-dev'
$script:AppRoot = Split-Path -Parent $PSScriptRoot

# The engine runtime: ONNX Runtime with DirectML, its .NET API and the Visual C++ runtime, every file Microsoft-signed
# and unmodified, packed by dev\runtime\Build-Runtime.ps1. The download is rejected unless the ZIP and each DLL in it
# match these SHA-256s.
$script:Runtime = [pscustomobject]@{
    Name   = 'hoopics-runtime-ort1.24.4-dml1.15.4-win-x64'
    Url    = 'https://github.com/WhoisHOO/HOOPICS/releases/download/runtime-ort1.24.4-dml1.15.4-r1/hoopics-runtime-ort1.24.4-dml1.15.4-win-x64.zip'
    Sha256 = '024859A755740A88A73956B96D898238F1B1884E7D65751168064CC5685740CB'
    Size   = 16058086
    Files  = @{
        'onnxruntime.dll'                            = 'E7EEDEC6A6F26DC39DC948276A75EF6D2BEE3FFF944D874CEED0BBD3B97BFF40'
        'DirectML.dll'                               = '9C9E6D822561C6C41B90E6994B3E8857CF1D66DBFB1E0C4C799C7C89B4E92DA1'
        'Microsoft.ML.OnnxRuntime.dll'               = '5C3C531AF36A6CB4BAA01DB20DCF94A0464EC36F8090AA42F35FF565B90A1EA6'
        'System.Memory.dll'                          = 'BF3FB84664F4097F1A8A9BC71A51DCF8CF1A905D4080A4D290DA1730866E856F'
        'System.Buffers.dll'                         = 'ACCCCFBE45D9F08FFEED9916E37B33E98C65BE012CFFF6E7FA7B67210CE1FEFB'
        'System.Numerics.Vectors.dll'                = '1D3EF8698281E7CF7371D1554AFEF5872B39F96C26DA772210A33DA041BA1183'
        'System.Runtime.CompilerServices.Unsafe.dll' = '66409F670315AFE8610F17A4D3A1EE52D72B6A46C544CEC97544E8385F90AD74'
        'msvcp140.dll'                               = '0F885B509A685D2BBFA652FED26B5FB31D88FBDAB0A978C641D1C7B8AA460AA9'
        'msvcp140_1.dll'                             = 'BFAD5AEF4C63A669E3C140655CDFDF395B6C979B400A447BD5DCB65ED8826C3D'
        'vcruntime140.dll'                           = 'D5E4D9A3E835FA679450145D6A7D94E36573A509317111904D9B3712C30D9066'
        'vcruntime140_1.dll'                         = '1F2D41C4AA5DB0BC33EBF7B66D72943A817D7CE6CBE880502A9403823633093F'
    }
}

# The AI models: two NERVE models by Philip Hofmann (Apache-2.0), converted to ONNX by dev\models\Build-Models.ps1
# from the author's checkpoints, whose hashes it pins. Checked like the runtime.
$script:ModelPack = [pscustomobject]@{
    Name   = 'hoopics-models-nerve-r1'
    Url    = 'https://github.com/WhoisHOO/HOOPICS/releases/download/models-nerve-r1/hoopics-models-nerve-r1.zip'
    Sha256 = 'F5818D4BCBB045F7EC63C59B6A097B656C6AE6C203377D07388D66753976245F'
    Size   = 20160696
    Files  = @{
        '4x_NERVE_OTF_gan.fp32.onnx'      = 'D681343E82527FD7B548601E9F793B04751195A6B57F63F3087463606AD7E0D4'
        '4x_NERVE_OTF_gan.fp16.onnx'      = '7F206D25A18E99F46512899839CD9A1C2B749498C441E58AFC5EB916E122E062'
        '4x_NERVE_OTF_fidelity.fp32.onnx' = 'E0CF7B571CD518C1ACE242B0755714FB2ECEBFBF7DA0E2A52A4C1EE7792C003E'
        '4x_NERVE_OTF_fidelity.fp16.onnx' = '4F31CB436DA3CF4953FF22D866D183DB2259CEBF6D9579A4A4660FBBF63BD935'
    }
}

# Models are <File>.fp32.onnx and <File>.fp16.onnx in the model folder. Every model runs at its native 4x and the
# result is resampled to the exact target size. Tile is the piece of the picture the GPU takes at once; Pad is the
# context around each piece that keeps the seams invisible: NERVE sees about 50 px around each pixel, and tiles
# stopped getting closer to the whole picture beyond 32 (docs\ROADMAP.md, stage 5).
# Anime and illustration get the fidelity model: the GAN one adds grain to flat colours and outlines.
$script:Models = [ordered]@{
    'anime' = @{ File = '4x_NERVE_OTF_fidelity'; Tile = 256; Pad = 32 }
    'photo' = @{ File = '4x_NERVE_OTF_gan'; Tile = 256; Pad = 32 }
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
    Join-Path $script:AppRoot 'engine'
}

function Get-RuntimeDirectory {
    if ($env:HOOPICS_RUNTIME_DIR) { return $env:HOOPICS_RUNTIME_DIR }
    Join-Path (Get-EngineDirectory) $script:Runtime.Name
}

function Get-ModelDirectory {
    if ($env:HOOPICS_MODEL_DIR) { return $env:HOOPICS_MODEL_DIR }
    Join-Path (Get-EngineDirectory) $script:ModelPack.Name
}

function Get-ModelPath([string]$Model) {
    Join-Path (Get-ModelDirectory) $script:Models[$Model].File
}

# What HOOPICS downloads, each into its own folder. Models in HOOPICS_MODEL_DIR are a developer's own and used as
# they are.
function Get-EnginePackage {
    [pscustomobject]@{ Package = $script:Runtime; Directory = Get-RuntimeDirectory; Error = 'Runtime' }
    if (-not $env:HOOPICS_MODEL_DIR) { [pscustomobject]@{ Package = $script:ModelPack; Directory = Get-ModelDirectory; Error = 'Model' } }
}

function Test-EnginePackage($Package, [string]$Directory) {
    # Every file, by its pinned SHA-256, each time: a damaged or swapped file means installing again.
    foreach ($file in $Package.Files.Keys) {
        $path = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Package.Files[$file]) { return $false }
    }
    $true
}

function Test-HoopicsEngine {
    foreach ($item in Get-EnginePackage) {
        if (-not (Test-EnginePackage $item.Package $item.Directory)) { return $false }
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

function Save-EngineArchive([string]$Url, [string]$Destination, $State, [double]$ProgressBase = 0, [double]$ProgressSpan = 100) {
    # GitHub needs TLS 1.2, which Windows PowerShell 5.1 does not always enable by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
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
                if ($total -gt 0) { Set-Progress $State 'Downloading the AI engine' ($ProgressBase + $ProgressSpan * $done / $total) }
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

function Assert-FileHash([string]$Path, [string]$Sha256) {
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -ne $Sha256) {
        throw (New-HoopicsError 'Checksum' ('{0}: expected {1}, got {2}' -f (Split-Path -Leaf $Path), $Sha256, $hash))
    }
}

function Expand-EngineArchive([string]$Path, [string]$Destination, $Package) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            # Only the pinned files and the license texts; neither pattern can climb out of $Destination.
            $name = $entry.FullName.Replace('\', '/')
            if (-not $Package.Files.ContainsKey($name) -and $name -notmatch '^licenses/[A-Za-z0-9._-]+\.(?:txt|md)$') { continue }
            $target = Join-Path $Destination $name.Replace('/', '\')
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
    foreach ($file in $Package.Files.Keys) {
        $path = Join-Path $Destination $file
        if (-not (Test-Path -LiteralPath $path)) { throw (New-HoopicsError 'Checksum' "$file is missing") }
        Assert-FileHash $path $Package.Files[$file]
    }
}

function Install-EnginePackage($Item, $State, [double]$ProgressBase, [double]$ProgressSpan) {
    $package, $target = $Item.Package, $Item.Directory
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    # Names of its own, so that two HOOPICS windows installing at once do not delete each other's files.
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $zip = Join-Path $parent "$($package.Name).$id.zip.part"
    $staging = "$target.$id.staging"
    try {
        Save-EngineArchive -Url $package.Url -Destination $zip -State $State -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan
        Assert-FileHash $zip $package.Sha256
        Expand-EngineArchive -Path $zip -Destination $staging -Package $package
        try {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
            Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $target) -ErrorAction Stop
        } catch {
            # Another HOOPICS may have installed it meanwhile, or a running engine holds the old files.
            if (-not (Test-EnginePackage $package $target)) { throw (New-HoopicsError $Item.Error $_.Exception.Message) }
        }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Downloads whatever is missing or damaged: the runtime, the models or both. Returns the runtime folder.
function Install-HoopicsEngine {
    param($State)
    $missing = @(Get-EnginePackage | Where-Object { -not (Test-EnginePackage $_.Package $_.Directory) })
    $total = [double](($missing | ForEach-Object { $_.Package.Size } | Measure-Object -Sum).Sum)
    $done = 0.0
    foreach ($item in $missing) {
        Install-EnginePackage $item $State (100.0 * $done / $total) (100.0 * $item.Package.Size / $total)
        $done += $item.Package.Size
    }
    Get-RuntimeDirectory
}

function Get-PowerShellPath {
    # The runtime is 64-bit; from a 32-bit PowerShell on 64-bit Windows, System32 would lead back to the 32-bit one.
    $folder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    Join-Path $env:SystemRoot "$folder\WindowsPowerShell\v1.0\powershell.exe"
}

# The engine is a child powershell.exe running app\engine\hoopics-engine.ps1. It stays up for a whole batch, so the
# model is loaded once, and takes one job per stdin line: arguments separated by tabs, in UTF-8 so any path works.
function Start-Engine {
    # The runtime is for x64; Windows on Arm runs PowerShell as Arm64, which cannot load it.
    if (@($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432) -contains 'ARM64') {
        throw (New-HoopicsError 'Runtime' 'Windows on Arm is not supported yet')
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-PowerShellPath
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'engine\hoopics-engine.ps1')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardError = $true
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $start.EnvironmentVariables['HOOPICS_RUNTIME'] = Get-RuntimeDirectory
    $script:EngineProcess = [Diagnostics.Process]::Start($start)
    $script:EngineProcess
}

function Stop-HoopicsEngine {
    $process = $script:EngineProcess
    $script:EngineProcess = $null
    if (-not $process) { return }
    try {
        # The end of its input makes the engine exit by itself.
        if (-not $process.HasExited) { $process.StandardInput.Close() }
        if (-not $process.WaitForExit(5000)) { $process.Kill() }
    } catch {
        # Already gone.
    } finally {
        $process.Dispose()
    }
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
    $spec = $script:Models[$Model]
    $job = @('-i', $InputFile, '-o', $OutputFile, '-m', (Get-ModelPath $Model), '-s', '4', '-t', $spec.Tile, '-x', $spec.Pad,
        '-c', (Join-Path (Get-EngineDirectory) 'choices.txt'))
    if ($env:HOOPICS_ENGINE_DEVICE) { $job += '-g', $env:HOOPICS_ENGINE_DEVICE }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($job -join "`t") + "`n")

    if ($State -and $State.CancelRequested) { throw (New-HoopicsError 'Canceled') }
    $process = $script:EngineProcess
    if (-not $process -or $process.HasExited) { $process = Start-Engine }
    if ($State) { $State.Process = $process }
    $log = New-Object Collections.Generic.List[string]
    $code = $null
    try {
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        # stderr: "12.50%" progress, "[tag] text" status, and "[done <exit code>]" when the job is over.
        while ($null -ne ($line = $process.StandardError.ReadLine())) {
            if ($line -match '^(\d+(?:\.\d+)?)%$') {
                Set-Progress $State 'Upscaling' ($ProgressBase + $ProgressSpan * [double]$Matches[1] / 100)
                continue
            }
            if ($line -match '^\[done (\d+)\]$') { $code = [int]$Matches[1]; break }
            if ($State) {
                if ($line -match '^\[calibrate\] measuring') { $State.Note = 'calibrate' }
                elseif ($line -match '^\[gpu\]') { $State.Note = $null }
                elseif ($line -match '^\[(cpu|fallback)\]') { $State.Note = 'cpu' }
            }
            $log.Add($line)
        }
    } catch [IO.IOException] {
        # The engine was gone before it could take the job: canceled, or it crashed.
    } finally {
        if ($State) { $State.Process = $null }
    }
    if ($State -and $State.CancelRequested) {
        Stop-HoopicsEngine
        throw (New-HoopicsError 'Canceled')
    }
    $detail = ($log | Where-Object { $_ -match '^\[error ' } | Select-Object -Last 1) -replace '^\[error \d+\] ', ''
    if ($null -eq $code) {
        # The engine ended without finishing the job; it exits with 3 when the runtime cannot load.
        if ($process.WaitForExit(5000)) { $code = $process.ExitCode }
        Stop-HoopicsEngine
        if ($code -eq 3) { throw (New-HoopicsError 'Runtime' $detail) }
        if (-not $detail) { $detail = ($log | Select-Object -Last 2) -join ' / ' }
        throw (New-HoopicsError 'Engine' ("the engine stopped (exit code {0}). {1}" -f $code, $detail))
    }
    switch ($code) {
        0 { }
        3 { Stop-HoopicsEngine; throw (New-HoopicsError 'Runtime' $detail) }
        4 { throw (New-HoopicsError 'Model' $detail) }
        default { throw (New-HoopicsError 'Engine' ("exit code {0}. {1}" -f $code, $detail)) }
    }
    if (-not (Test-Path -LiteralPath $OutputFile)) { throw (New-HoopicsError 'Engine' 'no output file') }
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

function New-WorkDirectory {
    # Private, as it holds the user's pictures. Any name works: the engine takes paths as UTF-8.
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('hoopics-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    try {
        New-PrivateDirectory $dir
    } catch {
        throw (New-HoopicsError 'WorkDir' $_.Exception.Message)
    }
    $dir
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
        [ValidateSet('anime', 'photo')] [string] $Model = 'anime',
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
                Invoke-Engine -InputFile $current -OutputFile $next -Model $Model -State $State `
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
    Get-HoopicsMonitor, Set-HoopicsWallpaper, Test-HoopicsEngine, Install-HoopicsEngine, Stop-HoopicsEngine, Get-HoopicsPlan,
    Get-HoopicsImageInfo, Invoke-HoopicsImage
