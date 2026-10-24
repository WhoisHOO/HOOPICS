<#
.SYNOPSIS
    DEVELOPMENT ONLY: runs the old Real-ESRGAN engine and the new HOOPICS engine on the same pictures and compares
    the results (PSNR, largest pixel difference) and the time each took.

.DESCRIPTION
    Needs the old engine installed by HOOPICS 0.1.1 (engine\realesrgan-ncnn-vulkan-20220424), its models converted
    with ncnn_to_onnx.py into engine\models, and the engine runtime that HOOPICS installs. Nothing here is shipped.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dev\parity\Compare-Engines.ps1 -Images C:\pics\a.png
#>
param(
    [Parameter(Mandatory)] [string[]] $Images,
    [string] $Runtime = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'engine\hoopics-runtime-ort1.24.4-dml1.15.4-win-x64'),
    [ValidateSet('anime', 'anime-sharp', 'photo')] [string[]] $Models = @('anime', 'anime-sharp', 'photo'),
    [string] $Device = 'auto',
    [string] $Precision = 'auto',
    [int] $Tile = 256,
    [int] $Pad = 16,
    [string] $OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'hoopics-parity')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$oldEngine = Join-Path $root 'engine\realesrgan-ncnn-vulkan-20220424'
$names = @{ 'anime' = 'realesr-animevideov3'; 'anime-sharp' = 'realesrgan-x4plus-anime'; 'photo' = 'realesrgan-x4plus' }
$files = @{ 'anime' = 'realesr-animevideov3-x4'; 'anime-sharp' = 'realesrgan-x4plus-anime'; 'photo' = 'realesrgan-x4plus' }
$Runtime = (Resolve-Path -LiteralPath $Runtime).ProviderPath
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class HoopicsParity
{
    // Returns { PSNR in dB over RGB (99 when identical), largest RGB difference, largest alpha difference }.
    public static double[] Compare(string a, string b)
    {
        using (var x = new Bitmap(a))
        using (var y = new Bitmap(b))
        {
            if (x.Width != y.Width || x.Height != y.Height) throw new Exception("sizes differ: " + a + " / " + b);
            byte[] p = Pixels(x), q = Pixels(y);
            double sum = 0; int max = 0, maxAlpha = 0;
            for (int i = 0; i < p.Length; i += 4)
            {
                for (int c = 0; c < 3; c++)
                {
                    int d = Math.Abs(p[i + c] - q[i + c]);
                    sum += d * d;
                    if (d > max) max = d;
                }
                maxAlpha = Math.Max(maxAlpha, Math.Abs(p[i + 3] - q[i + 3]));
            }
            double mse = sum / (p.Length / 4 * 3);
            return new double[] { mse == 0 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse), max, maxAlpha };
        }
    }

    static byte[] Pixels(Bitmap bitmap)
    {
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { bitmap.UnlockBits(data); }
    }
}
'@

function Invoke-Timed([string]$File, [string[]]$Arguments) {
    # Both engines write their progress to stderr, which must not count as an error here.
    $ErrorActionPreference = 'Continue'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $log = & $File @Arguments 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -notmatch '^[\d.]+%$' }
    [pscustomobject]@{ Seconds = $watch.Elapsed.TotalSeconds; ExitCode = $LASTEXITCODE; Log = @($log) }
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$engineScript = Join-Path $root 'app\engine\hoopics-engine.ps1'
foreach ($image in $Images) {
    $image = (Resolve-Path -LiteralPath $image).ProviderPath
    $stem = [IO.Path]::GetFileNameWithoutExtension($image)
    foreach ($model in $Models) {
        $old = Join-Path $OutDir "$stem.$model.ncnn.png"
        $new = Join-Path $OutDir "$stem.$model.hoopics.png"
        Remove-Item -LiteralPath $old, $new -Force -ErrorAction SilentlyContinue
        $a = Invoke-Timed (Join-Path $oldEngine 'realesrgan-ncnn-vulkan.exe') @(
            '-i', $image, '-o', $old, '-n', $names[$model], '-s', '4', '-m', (Join-Path $oldEngine 'models'))
        $b = Invoke-Timed $powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineScript,
            '-i', $image, '-o', $new, '-m', (Join-Path $root "engine\models\$($files[$model])"), '-r', $Runtime,
            '-c', (Join-Path $root 'engine\choices.txt'), '-g', $Device, '-p', $Precision, '-t', $Tile, '-x', $Pad)
        $result = if ((Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath $new)) { [HoopicsParity]::Compare($old, $new) } else { @($null, $null, $null) }
        [pscustomobject]@{
            Image     = $stem
            Model     = $model
            OldSec    = [Math]::Round($a.Seconds, 1)
            NewSec    = [Math]::Round($b.Seconds, 1)
            NewExit   = $b.ExitCode
            PsnrDb    = if ($null -ne $result[0]) { [Math]::Round($result[0], 2) } else { $null }
            MaxDiff   = $result[1]
            AlphaDiff = $result[2]
            NewLog    = ($b.Log | Where-Object { $_ -match '^\[' }) -join ' | '
        }
    }
}
