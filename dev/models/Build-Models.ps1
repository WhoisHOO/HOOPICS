<#
.SYNOPSIS
    Builds the HOOPICS model ZIP: two NERVE models by Philip Hofmann (Apache-2.0), converted to the ONNX files the
    engine opens.

.DESCRIPTION
    The release workflow (.github/workflows/models.yml) runs this and publishes the ZIP; HOOPICS downloads it once and
    checks it against the hashes pinned in app\HOOPICS.Core.psm1. The checkpoints and the license come from the
    author's Hugging Face repository at a pinned commit, each with its pinned SHA-256. nerve_to_onnx.py (Python with
    numpy) reads them without torch or pickle and writes fp32 and fp16 ONNX files, which must match their pinned
    SHA-256s too, so the result is the same on every build machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dev\models\Build-Models.ps1 -OutDir C:\tmp\models
#>
param(
    [Parameter(Mandatory)] [string] $OutDir,
    # A Python 3 with numpy.
    [string] $Python = 'python',
    # Folders with already-downloaded files, searched by file name, to skip the downloads.
    [string[]] $Cache
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Name = 'hoopics-models-nerve-r1'
$Commit = '3619eb1a67d775d9357bdb808336700e681b3eaf'
$Repository = "https://huggingface.co/Phips/NERVE/resolve/$Commit/"

# From the author's repository; the SHA-256s are those Hugging Face lists for the files, read 2026-10-24.
$Sources = @(
    @{ Path = 'models/4x_NERVE_OTF_gan.safetensors'; Sha256 = 'b1c0c041293ec0d327ee3b59253cd27177190c403760fe1f0e8f88084e6a2faf' }
    @{ Path = 'models/4x_NERVE_OTF_fidelity.safetensors'; Sha256 = 'e05f589bde0ba0bb18b55e881b0160b52986df71ce472a6fa28c1e81179adae7' }
    @{ Path = 'LICENSE'; Sha256 = 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30' }
)

# Every model file in the ZIP, as the app checks it.
$Expected = @{
    '4x_NERVE_OTF_gan.fp32.onnx'      = 'd681343e82527fd7b548601e9f793b04751195a6b57f63f3087463606ad7e0d4'
    '4x_NERVE_OTF_gan.fp16.onnx'      = '7f206d25a18e99f46512899839cd9a1c2b749498c441e58afc5eb916e122e062'
    '4x_NERVE_OTF_fidelity.fp32.onnx' = 'e0cf7b571cd518c1ace242b0755714fb2ecebfbf7da0e2a52a4c1ee7792c003e'
    '4x_NERVE_OTF_fidelity.fp16.onnx' = '4f31cb436da3cf4953ff22d866d183db2259cebf6d9579a4a4660fbbf63bd935'
}

$Notice = @"
The ONNX files next to this folder are two NERVE models by Philip Hofmann, from
https://huggingface.co/Phips/NERVE at commit $Commit, released under the Apache License 2.0
(NERVE-LICENSE.txt). They were trained only on the dataset Phips/lucid-cc0-v2-hc-512, which its author
describes as CC0 photos from PxHere.

HOOPICS changed them as follows:
- 4x_NERVE_OTF_gan and 4x_NERVE_OTF_fidelity were converted from the author's .safetensors checkpoints to ONNX
  by dev/models/nerve_to_onnx.py in the HOOPICS repository (https://github.com/WhoisHOO/HOOPICS).
- The network's bicubic enlargement of its input is written as a fixed 5x5 convolution that computes the same thing.
- The .fp16.onnx files store the weights in half precision; the .fp32.onnx files keep them as published.
- The metadata entries hoopics.scale and hoopics.source were added.
"@

function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-Download([string]$Url, [string]$FileName) {
    $target = Join-Path $downloads $FileName
    $cached = foreach ($dir in $Cache) { Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $FileName }
    $cached = @($cached)[0]
    if ($cached) { Copy-Item -LiteralPath $cached.FullName $target } else { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $target }
    $target
}

$downloads = Join-Path $OutDir 'downloads'
$stage = Join-Path $OutDir $Name
foreach ($dir in $downloads, $stage) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
}
New-Item -ItemType Directory -Path (Join-Path $stage 'licenses') | Out-Null

# 1. The checkpoints and the license, each checked against its pin.
$files = @{}
foreach ($source in $Sources) {
    $path = Get-Download ($Repository + $source.Path) ($source.Path -replace '^.*/', '')
    if ((Get-Sha256 $path) -ne $source.Sha256) { throw "$($source.Path) does not match its pinned SHA-256" }
    $files[$source.Path] = $path
    Write-Host "huggingface.co  $($source.Path)  SHA-256 matches the pin"
}

# 2. Convert. The converter writes <prefix>.fp32.onnx and <prefix>.fp16.onnx.
$converter = Join-Path $PSScriptRoot 'nerve_to_onnx.py'
foreach ($source in $Sources | Where-Object { $_.Path -like '*.safetensors' }) {
    $prefix = Join-Path $stage ([IO.Path]::GetFileNameWithoutExtension($source.Path))
    & $Python -I $converter $files[$source.Path] $prefix
    if ($LASTEXITCODE) { throw "nerve_to_onnx.py failed on $($source.Path)" }
}
Copy-Item -LiteralPath $files['LICENSE'] (Join-Path $stage 'licenses\NERVE-LICENSE.txt')
[IO.File]::WriteAllText((Join-Path $stage 'licenses\NERVE-NOTICE.txt'), $Notice.Replace("`r`n", "`n"))

# 3. Check every model file, then pack with fixed timestamps so the same inputs give the same ZIP.
$models = @(Get-ChildItem -LiteralPath $stage -Filter *.onnx -File)
if ($models.Count -ne $Expected.Count) { throw "expected $($Expected.Count) model files, got $($models.Count)" }
foreach ($model in $models) {
    $hash = Get-Sha256 $model.FullName
    if ($hash -ne $Expected[$model.Name]) { throw "$($model.Name): SHA-256 $hash is not the pinned one" }
    Write-Host ('{0,-34} {1}' -f $model.Name, $hash)
}
$zipPath = Join-Path $OutDir "$Name.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    [string[]]$entries = Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1).Replace('\', '/') }
    [Array]::Sort($entries, [StringComparer]::Ordinal)
    foreach ($file in $entries) {
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
    sources = @($Sources | ForEach-Object { [ordered]@{ url = $Repository + $_.Path; sha256 = $_.Sha256 } })
    files   = @($models | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; sha256 = $Expected[$_.Name]; size = $_.Length } })
}
[IO.File]::WriteAllText((Join-Path $OutDir "$Name.manifest.json"), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host "$zipPath  SHA-256 $zipHash"
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value @("name=$Name", "zip=$zipPath", "sha256=$zipHash", "manifest=$(Join-Path $OutDir "$Name.manifest.json")")
}
