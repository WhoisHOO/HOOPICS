# Runs the HOOPICS engine: loads ONNX Runtime's managed API from the runtime folder, compiles HoopicsEngine.cs and
# enlarges pictures. HOOPICS.Core.psm1 starts it as a child powershell.exe, so a GPU or driver crash cannot take the
# window down. Every program file Windows loads is signed by Microsoft; Add-Type's own compiled code is loaded from
# memory, as for app\Native.cs.
#
#   hoopics-engine.ps1 -r <runtime folder> -i in.png -o out.png -m <model> ...   one picture; see HoopicsEngine.cs
#   hoopics-engine.ps1                                                            one job per stdin line (UTF-8,
#                                                                                 arguments separated by tabs)
# Without -r the runtime folder comes from %HOOPICS_RUNTIME%.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.

$ErrorActionPreference = 'Stop'

$runtime = $env:HOOPICS_RUNTIME
for ($i = 0; $i -lt $args.Count - 1; $i++) {
    if ($args[$i] -eq '-r') { $runtime = $args[$i + 1] }
}

try {
    if (-not $runtime) { throw 'give the runtime folder with -r or HOOPICS_RUNTIME' }
    # ONNX Runtime's managed API and its dependencies, loaded by path; each finds the next in the same folder.
    $references = foreach ($name in 'System.Runtime.CompilerServices.Unsafe', 'System.Buffers', 'System.Numerics.Vectors', 'System.Memory', 'Microsoft.ML.OnnxRuntime') {
        $path = Join-Path $runtime "$name.dll"
        [void][Reflection.Assembly]::LoadFrom($path)
        $path
    }
    Add-Type -AssemblyName PresentationCore, WindowsBase, System.Xaml
    $framework = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $references += @(
        (Join-Path $framework 'netstandard.dll'),
        [Windows.Media.Imaging.BitmapSource].Assembly.Location,
        [Windows.Threading.Dispatcher].Assembly.Location,
        [System.Xaml.XamlType].Assembly.Location
    )
    Add-Type -Path (Join-Path $PSScriptRoot 'HoopicsEngine.cs') -ReferencedAssemblies $references
} catch {
    # HOOPICS reads a serving engine's messages as UTF-8, whatever the console code page is.
    $message = '[error 3] cannot start the engine: ' + ($_.Exception.Message -replace '\s+', ' ')
    if ($args.Count -eq 0) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($message + [Environment]::NewLine)
        $stderr = [Console]::OpenStandardError()
        $stderr.Write($bytes, 0, $bytes.Length)
        $stderr.Flush()
    } else {
        [Console]::Error.WriteLine($message)
    }
    exit 3
}

if ($args.Count -gt 0) {
    exit [Hoopics.Engine.Program]::Run([string[]]$args)
}
exit [Hoopics.Engine.Program]::Serve()
