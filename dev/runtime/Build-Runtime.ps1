<#
.SYNOPSIS
    Builds the HOOPICS engine runtime ZIP: ONNX Runtime with DirectML, its .NET API and the Visual C++ runtime, all
    Microsoft-signed, taken unmodified from Microsoft's own packages.

.DESCRIPTION
    The release workflow (.github/workflows/runtime.yml) runs this and publishes the ZIP; HOOPICS downloads it once and
    checks it against the hashes pinned in app\HOOPICS.Core.psm1. Every source is pinned here too:
    - NuGet packages from nuget.org: SHA-512 pinned, and checked against nuget.org's catalog.
    - The Visual C++ runtime from Microsoft's Visual Studio download server: SHA-256 of the package pinned.
    Each file that goes in must match its pinned SHA-256 and carry a valid Microsoft signature, so the result is the
    same on every build machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dev\runtime\Build-Runtime.ps1 -OutDir C:\tmp\runtime
#>
param(
    [Parameter(Mandatory)] [string] $OutDir,
    # Folders with already-downloaded .nupkg/.vsix files, searched by file name, to skip the downloads.
    [string[]] $Cache
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Name = 'hoopics-runtime-ort1.24.4-dml1.15.4-win-x64'

# NuGet packages: SHA-512 is nuget.org's catalog packageHash (base64), read 2026-10-24.
$Packages = @(
    @{ Id = 'Microsoft.ML.OnnxRuntime.DirectML'; Version = '1.24.4'
        Sha512 = 'ZjOyv495vhfVXoTJp2utRyn8ir1TFIvCj0B9JP8QZGBXS0oFx+lY7ZCZqSdnVShQX6EtxYi2T3VOtYXcmBTV4A=='
        Files = @{ 'runtimes/win-x64/native/onnxruntime.dll' = 'onnxruntime.dll'
            'LICENSE' = 'licenses/onnxruntime-LICENSE.txt'; 'ThirdPartyNotices.txt' = 'licenses/onnxruntime-ThirdPartyNotices.txt'
            'Privacy.md' = 'licenses/onnxruntime-Privacy.md' } }
    # Unlisted on nuget.org (its other platform folders were incomplete), still served by exact version.
    @{ Id = 'Microsoft.ML.OnnxRuntime.Managed'; Version = '1.24.4'
        Sha512 = 'wQClOZZ1HkQHNSr5cvXYfMJ5wGsZ2GpNsfrlGI/pSdyd1PjGCNFMftioL0C0mATHCwJMuiezrthWQOEqrghf2A=='
        Files = @{ 'lib/netstandard2.0/Microsoft.ML.OnnxRuntime.dll' = 'Microsoft.ML.OnnxRuntime.dll' } }
    @{ Id = 'Microsoft.AI.DirectML'; Version = '1.15.4'
        Sha512 = '/edn9WkEq8kP1T9l2HKckYq39uPF4ezdR5kI/AK0U1zysIYPerKsubcx1suAm3LD1dTQKFP7j16gIqR7xE7yhQ=='
        Files = @{ 'bin/x64-win/DirectML.dll' = 'DirectML.dll'
            'LICENSE.txt' = 'licenses/DirectML-LICENSE.txt'; 'ThirdPartyNotices.txt' = 'licenses/DirectML-ThirdPartyNotices.txt' } }
    # The .NET Framework builds (net461/net46): their assembly versions match what System.Memory asks for.
    @{ Id = 'System.Memory'; Version = '4.5.5'
        Sha512 = '6MjlNsl7lKw0Q8lAsw2tQ89ul9x6jD2Yk3EEj+dOFoYGOE9eAUO9wNhvd4O/n97oQXlkyzqKXXUnE+kLElFy3A=='
        Files = @{ 'lib/net461/System.Memory.dll' = 'System.Memory.dll'
            'LICENSE.TXT' = 'licenses/dotnet-LICENSE.txt'; 'THIRD-PARTY-NOTICES.TXT' = 'licenses/dotnet-THIRD-PARTY-NOTICES.txt' } }
    @{ Id = 'System.Buffers'; Version = '4.5.1'
        Sha512 = 'gNphWOVbm89+C15jebnPRaYykU8De1PFv1YJV24814IfeGGVa3PXRHDS0MLlbdI1pe9Mpv/n4ZK4INwtAjqv8g=='
        Files = @{ 'lib/net461/System.Buffers.dll' = 'System.Buffers.dll' } }
    @{ Id = 'System.Numerics.Vectors'; Version = '4.5.0'
        Sha512 = 'nATsBTD2CKr4AYN6eRszhX4sptImWmBJwB/U6XKCWWfnCcrTBw8XSCm3QA9gjppkHTr8OkXUY21MR91D3QZXsw=='
        Files = @{ 'lib/net46/System.Numerics.Vectors.dll' = 'System.Numerics.Vectors.dll' } }
    @{ Id = 'System.Runtime.CompilerServices.Unsafe'; Version = '4.5.3'
        Sha512 = 'dl2H02p7dBXe5bbL06COrZdikV+/rPrYogWnjUoYfOxmd9okB/f3wtG1X+n4wCV5JcmwvBk9QClywyOXlni6qw=='
        Files = @{ 'lib/net461/System.Runtime.CompilerServices.Unsafe.dll' = 'System.Runtime.CompilerServices.Unsafe.dll' } }
)

# Visual C++ runtime 14.44 (Visual Studio 2022 17.14): onnxruntime.dll 1.24.4 was linked with 14.44 and fails to
# start with an older msvcp140.dll.
$VcRuntime = @{
    Url    = 'https://download.visualstudio.microsoft.com/download/pr/45d3b8dd-bced-4b37-9974-142f748d710c/4aaf54db0bfc9435f7c3660e1a00237a4b556042bfeea64bde44c2e0194e6ee5/Microsoft.VC.14.44.17.14.CRT.Redist.X64.base.vsix'
    Sha256 = '4aaf54db0bfc9435f7c3660e1a00237a4b556042bfeea64bde44c2e0194e6ee5'
    Folder = 'Contents/VC/Redist/MSVC/14.44.35112/x64/Microsoft.VC143.CRT/'
    Files  = 'msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
}

# Every program file in the runtime, as the app checks it.
$Expected = @{
    'onnxruntime.dll'                             = 'e7eedec6a6f26dc39dc948276a75ef6d2bee3fff944d874ceed0bbd3b97bff40'
    'DirectML.dll'                                = '9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1'
    'Microsoft.ML.OnnxRuntime.dll'                = '5c3c531af36a6cb4baa01db20dcf94a0464ec36f8090aa42f35ff565b90a1ea6'
    'System.Memory.dll'                           = 'bf3fb84664f4097f1a8a9bc71a51dcf8cf1a905d4080a4d290da1730866e856f'
    'System.Buffers.dll'                          = 'accccfbe45d9f08ffeed9916e37b33e98c65be012cfff6e7fa7b67210ce1fefb'
    'System.Numerics.Vectors.dll'                 = '1d3ef8698281e7cf7371d1554afef5872b39f96c26da772210a33da041ba1183'
    'System.Runtime.CompilerServices.Unsafe.dll'  = '66409f670315afe8610f17a4d3a1ee52d72b6a46c544cec97544e8385f90ad74'
    'msvcp140.dll'                                = '0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9'
    'msvcp140_1.dll'                              = 'bfad5aef4c63a669e3c140655cdfdf395b6c979b400a447bd5dcb65ed8826c3d'
    'vcruntime140.dll'                            = 'd5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066'
    'vcruntime140_1.dll'                          = '1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f'
}

$VcNotice = @'
msvcp140.dll, msvcp140_1.dll, vcruntime140.dll and vcruntime140_1.dll are the Microsoft Visual C++ runtime,
version 14.44.35211, copied unmodified from Microsoft's Visual Studio 2022 redistributable files
(Microsoft.VC.14.44.17.14.CRT.Redist.X64). They are redistributed with HOOPICS under the Visual Studio license
terms for Distributable Code; HOOPICS's MIT license does not apply to them.

Copyright (c) Microsoft Corporation. All rights reserved.
You may not modify, reverse engineer, or separately redistribute these files.
'@

function Get-Json([string]$Url) {
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $request.UserAgent = 'HOOPICS-runtime-build'
    $response = $request.GetResponse()
    try { ConvertFrom-Json (New-Object IO.StreamReader $response.GetResponseStream()).ReadToEnd() } finally { $response.Close() }
}

function Get-Hash([string]$Path, [string]$Algorithm) {
    $hasher = [Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    $stream = [IO.File]::OpenRead($Path)
    try { $hasher.ComputeHash($stream) } finally { $stream.Dispose(); $hasher.Dispose() }
}

function Get-Sha256([string]$Path) { -join ((Get-Hash $Path 'SHA256') | ForEach-Object { $_.ToString('x2') }) }

function Get-Download([string]$Url, [string]$FileName) {
    $target = Join-Path $downloads $FileName
    $cached = foreach ($dir in $Cache) { Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $FileName }
    $cached = @($cached)[0]
    if ($cached) { Copy-Item -LiteralPath $cached.FullName $target } else { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $target }
    $target
}

# Signed by Microsoft: the Windows catalog may vouch for a file ("Microsoft Windows Publisher") where another PC
# reads the embedded signature ("Microsoft Corporation"), so match the organization, and require an embedded one.
function Assert-MicrosoftSigned([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { throw "$Path signature: $($signature.Status) $($signature.StatusMessage)" }
    if ($signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw "$Path is signed by $($signature.SignerCertificate.Subject)" }
    $embedded = [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($Path).Subject
    if ($embedded -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw "$Path has no embedded Microsoft signature ($embedded)" }
    $signature.SignerCertificate.Subject
}

$downloads = Join-Path $OutDir 'downloads'
$stage = Join-Path $OutDir $Name
foreach ($dir in $downloads, $stage) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
}
New-Item -ItemType Directory -Path (Join-Path $stage 'licenses') | Out-Null

# 1. NuGet packages, located through nuget.org's service index as its API documentation asks.
$index = Get-Json 'https://api.nuget.org/v3/index.json'
$registrations = ($index.resources | Where-Object { $_.'@type' -eq 'RegistrationsBaseUrl/3.6.0' } | Select-Object -First 1).'@id'
$packageBase = ($index.resources | Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } | Select-Object -First 1).'@id'
$sources = foreach ($package in $Packages) {
    $id = $package.Id.ToLowerInvariant()
    $catalog = Get-Json (Get-Json ('{0}{1}/{2}.json' -f $registrations, $id, $package.Version)).catalogEntry
    if ($catalog.packageHashAlgorithm -ne 'SHA512' -or $catalog.packageHash -ne $package.Sha512) {
        throw "$($package.Id) $($package.Version): nuget.org lists hash $($catalog.packageHash), not the pinned one"
    }
    $file = '{0}.{1}.nupkg' -f $id, $package.Version
    $path = Get-Download ('{0}{1}/{2}/{3}' -f $packageBase, $id, $package.Version, $file) $file
    if ([Convert]::ToBase64String((Get-Hash $path 'SHA512')) -ne $package.Sha512) { throw "$file does not match its pinned SHA-512" }
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        foreach ($entry in $package.Files.Keys) {
            $found = $zip.GetEntry($entry)
            if (-not $found) { throw "$file has no $entry" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($found, (Join-Path $stage $package.Files[$entry]))
        }
    } finally {
        $zip.Dispose()
    }
    Write-Host "nuget.org  $file  SHA-512 matches the pin and nuget.org's catalog"
    [ordered]@{ package = $package.Id; version = $package.Version; sha512 = $package.Sha512 }
}

# 2. The Visual C++ runtime.
$vsix = Get-Download $VcRuntime.Url ($VcRuntime.Url -replace '^.*/', '')
if ((Get-Sha256 $vsix) -ne $VcRuntime.Sha256) { throw "$vsix does not match its pinned SHA-256" }
$zip = [IO.Compression.ZipFile]::OpenRead($vsix)
try {
    foreach ($file in $VcRuntime.Files) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($VcRuntime.Folder + $file), (Join-Path $stage $file))
    }
} finally {
    $zip.Dispose()
}
[IO.File]::WriteAllText((Join-Path $stage 'licenses\VisualCppRuntime-NOTICE.txt'), $VcNotice.Replace("`r`n", "`n"))
Write-Host "download.visualstudio.microsoft.com  Visual C++ runtime 14.44  SHA-256 matches the pin"

# 3. Check every program file, then pack with fixed timestamps so the same inputs give the same ZIP.
$dlls = @(Get-ChildItem -LiteralPath $stage -Filter *.dll -File)
if ($dlls.Count -ne $Expected.Count) { throw "expected $($Expected.Count) DLLs, got $($dlls.Count)" }
foreach ($dll in $dlls) {
    $hash = Get-Sha256 $dll.FullName
    if ($hash -ne $Expected[$dll.Name]) { throw "$($dll.Name): SHA-256 $hash is not the pinned one" }
    $signer = Assert-MicrosoftSigned $dll.FullName
    Write-Host ('{0,-45} {1}  {2}' -f $dll.Name, $hash, $signer)
}
$zipPath = Join-Path $OutDir "$Name.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    [string[]]$files = Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1).Replace('\', '/') }
    [Array]::Sort($files, [StringComparer]::Ordinal)
    foreach ($file in $files) {
        $entry = $zip.CreateEntry($file, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = New-Object DateTimeOffset 2026, 1, 1, 0, 0, 0, ([TimeSpan]::Zero)
        $in = [IO.File]::OpenRead((Join-Path $stage $file))
        $out = $entry.Open()
        try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
    }
} finally {
    $zip.Dispose()
}
$zipHash = Get-Sha256 $zipPath

$manifest = [ordered]@{
    name    = $Name
    zip     = [ordered]@{ file = "$Name.zip"; sha256 = $zipHash; size = (Get-Item -LiteralPath $zipPath).Length }
    sources = @($sources) + @([ordered]@{ package = 'Microsoft.VC.14.44.17.14.CRT.Redist.X64'; url = $VcRuntime.Url; sha256 = $VcRuntime.Sha256 })
    files   = @($dlls | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; sha256 = $Expected[$_.Name]; size = $_.Length } })
}
[IO.File]::WriteAllText((Join-Path $OutDir "$Name.manifest.json"), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host "$zipPath  SHA-256 $zipHash"
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value @("zip=$zipPath", "sha256=$zipHash", "manifest=$(Join-Path $OutDir "$Name.manifest.json")")
}
