// HOOPICS engine: enlarges PNG pictures with an ONNX super-resolution model, on the GPU through DirectML or on the CPU.
// hoopics-engine.ps1 compiles this file with Add-Type and runs it in a child Windows PowerShell 5.1 process, so it
// is C# 5 for the .NET Framework compiler. Keep it ASCII-only.
//
// A job is one picture:
//   -i in.png -o out.png -m <model prefix> [-s scale] [-t tile] [-x pad] [-g auto|cpu|<device>] [-p auto|fp32|fp16]
//   [-r <runtime folder>] [-c <choices file>]
// The model prefix names <prefix>.fp32.onnx and/or <prefix>.fp16.onnx; both take and return float32 NCHW RGB in [0, 1].
// The runtime folder holds ONNX Runtime, DirectML and the Visual C++ runtime; it defaults to %HOOPICS_RUNTIME%.
// Program.Run does one job from the command line. Program.Serve reads one job per input line, its arguments
// separated by tabs, and keeps the model open between jobs; it ends each job with "[done <exit code>]".
// stderr carries "12.50%" progress lines and "[tag] text" status lines. Exit codes are listed in ExitCode.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Hoopics.Engine
{
    public static class ExitCode
    {
        public const int Ok = 0;
        public const int Usage = 2;
        public const int Runtime = 3;      // ONNX Runtime or the Visual C++ runtime could not be loaded
        public const int Model = 4;        // the model file is missing or ONNX Runtime rejected it
        public const int Read = 5;         // the input picture could not be read
        public const int Write = 6;        // the output picture could not be written
        public const int Inference = 7;    // the model failed on every device, the CPU included
    }

    public sealed class EngineException : Exception
    {
        public readonly int Code;
        public EngineException(int code, string message) : base(message) { Code = code; }
        public EngineException(int code, string message, Exception inner) : base(message, inner) { Code = code; }
    }

    public static class Program
    {
        public static int Run(string[] args)
        {
            int code = Job(args);
            Upscaler.Release();
            return code;
        }

        // Jobs and messages are UTF-8 both ways, whatever the console code page is.
        public static int Serve()
        {
            var utf8 = new UTF8Encoding(false);
            var error = new StreamWriter(Console.OpenStandardError(), utf8);
            error.AutoFlush = true;
            Console.SetError(error);
            var input = new StreamReader(Console.OpenStandardInput(), utf8);
            string line;
            while ((line = input.ReadLine()) != null && line.Length > 0)
            {
                int code = Job(line.Split('\t'));
                Log.Done(code);
                // The pictures are large arrays; give the memory back before waiting for the next job.
                GC.Collect();
            }
            Upscaler.Release();
            return ExitCode.Ok;
        }

        static int Job(string[] args)
        {
            try
            {
                Options options = Options.Parse(args);
                Runtime.Load(options.RuntimeDir);
                new Upscaler(options).Run();
                return ExitCode.Ok;
            }
            catch (EngineException e)
            {
                Log.Error(e.Code, Describe(e));
                return e.Code;
            }
            catch (Exception e)
            {
                Log.Error(ExitCode.Inference, Describe(e));
                return ExitCode.Inference;
            }
        }

        static string Describe(Exception e)
        {
            var text = new StringBuilder(e.Message);
            for (Exception inner = e.InnerException; inner != null; inner = inner.InnerException) text.Append(" / ").Append(inner.Message);
            return Log.OneLine(text.ToString(), 600);
        }
    }

    static class Log
    {
        public static void Info(string tag, string text) { Console.Error.WriteLine("[" + tag + "] " + text); }

        public static void Error(int code, string text) { Console.Error.WriteLine("[error " + code + "] " + text); }

        public static void Done(int code) { Console.Error.WriteLine("[done " + code + "]"); }

        public static void Progress(double percent)
        {
            Console.Error.WriteLine(percent.ToString("0.00", CultureInfo.InvariantCulture) + "%");
        }

        public static string OneLine(string text, int max)
        {
            text = text.Replace("\r", " ").Replace("\n", " ");
            return text.Length > max ? text.Substring(0, max) + "..." : text;
        }
    }

    sealed class Options
    {
        public string Input, Output, Model, ChoicesFile;
        public string RuntimeDir = Environment.GetEnvironmentVariable("HOOPICS_RUNTIME");
        public string Device = "auto", Precision = "auto";
        public int Scale = 0, Tile = 256, Pad = 16;

        public static Options Parse(string[] args)
        {
            var o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                string key = args[i];
                if (i + 1 >= args.Length) throw Usage("missing value after " + key);
                string value = args[++i];
                switch (key)
                {
                    case "-i": o.Input = value; break;
                    case "-o": o.Output = value; break;
                    case "-m": o.Model = value; break;
                    case "-r": o.RuntimeDir = value; break;
                    case "-c": o.ChoicesFile = value; break;
                    case "-g": o.Device = value.ToLowerInvariant(); break;
                    case "-p": o.Precision = value.ToLowerInvariant(); break;
                    case "-s": o.Scale = Number(key, value, 1, 16); break;
                    case "-t": o.Tile = Number(key, value, 16, 4096); break;
                    case "-x": o.Pad = Number(key, value, 0, 256); break;
                    default: throw Usage("unknown option " + key);
                }
            }
            if (string.IsNullOrEmpty(o.Input) || string.IsNullOrEmpty(o.Output) || string.IsNullOrEmpty(o.Model))
                throw Usage("-i, -o and -m are required");
            if (string.IsNullOrEmpty(o.RuntimeDir)) throw Usage("give the runtime folder with -r or HOOPICS_RUNTIME");
            if (o.Precision != "auto" && o.Precision != "fp32" && o.Precision != "fp16") throw Usage("-p must be auto, fp32 or fp16");
            int device;
            if (o.Device != "auto" && o.Device != "cpu" && !int.TryParse(o.Device, NumberStyles.Integer, CultureInfo.InvariantCulture, out device))
                throw Usage("-g must be auto, cpu or a device number");
            return o;
        }

        static int Number(string key, string value, int min, int max)
        {
            int n;
            if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) || n < min || n > max)
                throw Usage(key + " must be a whole number from " + min + " to " + max);
            return n;
        }

        static EngineException Usage(string message) { return new EngineException(ExitCode.Usage, message); }
    }

    // Loads onnxruntime.dll and the Visual C++ runtime from our runtime folder by full path, before ONNX Runtime's
    // managed code looks for "onnxruntime" by name: Windows 11 has an older System32\onnxruntime.dll that would win,
    // and a PC may have no Visual C++ runtime, or an older one. ONNX Runtime itself loads the DirectML.dll next to it.
    static class Runtime
    {
        const uint LoadWithAlteredSearchPath = 0x8;
        static readonly Version MinimumVcRuntime = new Version(14, 44);
        static string loadedFrom;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr GetModuleHandleW(string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern uint GetModuleFileNameW(IntPtr module, StringBuilder path, uint size);

        public static void Load(string dir)
        {
            dir = Path.GetFullPath(dir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (loadedFrom != null)
            {
                if (!string.Equals(loadedFrom, dir, StringComparison.OrdinalIgnoreCase))
                    throw new EngineException(ExitCode.Runtime, "the runtime is already loaded from " + loadedFrom);
                return;
            }
            if (!File.Exists(Path.Combine(dir, "onnxruntime.dll"))) throw new EngineException(ExitCode.Runtime, "onnxruntime.dll not found in " + dir);
            // ONNX Runtime 1.24 is built with Visual C++ 14.44. A runtime DLL that is already loaded is reused whatever
            // its version, and an old one makes onnxruntime.dll fail to start (Windows error 1114).
            foreach (string name in VcRuntime)
            {
                string loaded = ModulePath(name);
                if (loaded != null && !InFolder(loaded, dir) && FileVersion(loaded) < MinimumVcRuntime)
                    throw new EngineException(ExitCode.Runtime, "an older Visual C++ runtime is already loaded: " + loaded + " " + FileVersion(loaded));
            }
            foreach (string name in VcRuntime)
            {
                string path = Path.Combine(dir, name);
                if (File.Exists(path)) LoadOne(path);
            }
            LoadOne(Path.Combine(dir, "onnxruntime.dll"));
            // Loading by name could still have found another copy, such as Windows 11's own older onnxruntime.dll.
            if (!InFolder(ModulePath("onnxruntime.dll"), dir))
                throw new EngineException(ExitCode.Runtime, "another onnxruntime.dll is loaded: " + ModulePath("onnxruntime.dll"));
            Start(dir);
            loadedFrom = dir;
        }

        static readonly string[] VcRuntime = { "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll" };

        static bool InFolder(string path, string dir)
        {
            return path != null && string.Equals(Path.GetDirectoryName(path), dir, StringComparison.OrdinalIgnoreCase);
        }

        // Kept apart from Load so that nothing touches ONNX Runtime before onnxruntime.dll is in place.
        [MethodImpl(MethodImplOptions.NoInlining)]
        static void Start(string dir)
        {
            var options = new EnvironmentCreationOptions { logId = "HOOPICS", logLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR };
            OrtEnv env = OrtEnv.CreateInstanceWithOptions(ref options);
            // Best effort: ONNX Runtime has sent its start-up event to Windows' diagnostics by now.
            env.DisableTelemetryEvents();
            var runtime = new StringBuilder("ONNX Runtime " + env.GetVersionString() + " from " + Path.GetDirectoryName(ModulePath("onnxruntime.dll")));
            foreach (string name in VcRuntime)
            {
                string path = ModulePath(name);
                if (path != null) runtime.Append("; ").Append(name).Append(' ').Append(FileVersion(path)).Append(InFolder(path, dir) ? "" : " from " + path);
            }
            Log.Info("runtime", runtime.ToString());
        }

        static void LoadOne(string path)
        {
            if (LoadLibraryExW(path, IntPtr.Zero, LoadWithAlteredSearchPath) != IntPtr.Zero) return;
            int error = Marshal.GetLastWin32Error();
            string hint = error == 1114 ? " (an older Visual C++ runtime is probably in the way)" : error == 126 ? " (a DLL it needs is missing)" : "";
            throw new EngineException(ExitCode.Runtime, string.Format(CultureInfo.InvariantCulture,
                "cannot load {0}: Windows error {1}, {2}{3}", path, error, new System.ComponentModel.Win32Exception(error).Message, hint));
        }

        public static string ModulePath(string name)
        {
            IntPtr module = GetModuleHandleW(name);
            if (module == IntPtr.Zero) return null;
            var path = new StringBuilder(1024);
            return GetModuleFileNameW(module, path, (uint)path.Capacity) > 0 ? path.ToString() : null;
        }

        static Version FileVersion(string path)
        {
            FileVersionInfo info = FileVersionInfo.GetVersionInfo(path);
            return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
        }
    }

    // A GPU that ONNX Runtime's DirectML provider can use.
    sealed class Gpu
    {
        public int DeviceId;            // the DXGI adapter number, which the DirectML provider takes
        public string Name;
        public int VendorId, HardwareId;
        public bool Discrete;
        public int PerformanceRank;     // Windows' high-performance order, 0 first
        public long DriverVersion;

        public string Key
        {
            get { return string.Format(CultureInfo.InvariantCulture, "{0:X4}:{1:X4}:{2}:{3}", VendorId, HardwareId, DriverVersion, Name); }
        }

        // Discrete GPUs first, then in Windows' high-performance order. The DXGI adapter numbers alone say nothing:
        // they changed between boots on a laptop with two GPUs.
        public static List<Gpu> List()
        {
            var list = new List<Gpu>();
            Dictionary<int, long> drivers = Dxgi.DriverVersions();
            foreach (OrtEpDevice device in OrtEnv.Instance().GetEpDevices())
            {
                if (device.EpName != "DmlExecutionProvider") continue;
                IReadOnlyDictionary<string, string> meta = device.HardwareDevice.Metadata.Entries;
                IReadOnlyDictionary<string, string> options = device.EpOptions.Entries;
                string text;
                int id;
                if (!options.TryGetValue("device_id", out text) || !int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out id)) continue;
                var gpu = new Gpu { DeviceId = id, VendorId = (int)device.HardwareDevice.VendorId, HardwareId = (int)device.HardwareDevice.DeviceId, PerformanceRank = int.MaxValue };
                gpu.Name = meta.TryGetValue("Description", out text) ? text : device.HardwareDevice.Vendor;
                gpu.Discrete = meta.TryGetValue("Discrete", out text) && text == "1";
                int rank;
                if (meta.TryGetValue("DxgiHighPerformanceIndex", out text) && int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out rank)) gpu.PerformanceRank = rank;
                long driver;
                if (drivers.TryGetValue(id, out driver)) gpu.DriverVersion = driver;
                list.Add(gpu);
            }
            list.Sort((a, b) => a.Discrete != b.Discrete ? (a.Discrete ? -1 : 1) : a.PerformanceRank != b.PerformanceRank ? a.PerformanceRank.CompareTo(b.PerformanceRank) : a.DeviceId.CompareTo(b.DeviceId));
            return list;
        }
    }

    // The graphics driver version of each DXGI adapter, so a driver update measures fp16 against fp32 again.
    static class Dxgi
    {
        [DllImport("dxgi.dll")]
        static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        delegate int EnumAdapters1Fn(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        delegate int CheckInterfaceSupportFn(IntPtr self, ref Guid iid, out long version);

        // Vtable slots: IUnknown 0-2, IDXGIObject 3-6, IDXGIFactory 7-11, IDXGIFactory1.EnumAdapters1 12;
        // IDXGIAdapter.CheckInterfaceSupport 9, which reports the user-mode driver version for IDXGIDevice.
        static T Method<T>(IntPtr com, int slot) where T : class
        {
            IntPtr vtable = Marshal.ReadIntPtr(com);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtable, slot * IntPtr.Size), typeof(T));
        }

        public static Dictionary<int, long> DriverVersions()
        {
            var versions = new Dictionary<int, long>();
            Guid iidFactory1 = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            Guid iidDevice = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            IntPtr factory;
            try
            {
                if (CreateDXGIFactory1(ref iidFactory1, out factory) != 0) return versions;
            }
            catch (DllNotFoundException)
            {
                return versions;
            }
            try
            {
                var enumAdapters = Method<EnumAdapters1Fn>(factory, 12);
                for (uint i = 0; i < 16; i++)
                {
                    IntPtr adapter;
                    if (enumAdapters(factory, i, out adapter) != 0) break;
                    try
                    {
                        long version;
                        if (Method<CheckInterfaceSupportFn>(adapter, 9)(adapter, ref iidDevice, out version) == 0) versions[(int)i] = version;
                    }
                    finally { Marshal.Release(adapter); }
                }
            }
            finally { Marshal.Release(factory); }
            return versions;
        }
    }

    // A picture in memory as 8-bit BGRA, read and written with the Windows Imaging Component.
    sealed class Picture
    {
        public int Width, Height;
        public byte[] Pixels;   // BGRA, Width * 4 bytes per row
        public bool HasAlpha;

        public static Picture Read(string path)
        {
            try
            {
                using (var stream = File.OpenRead(path))
                {
                    var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
                    var bgra = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
                    var p = new Picture { Width = bgra.PixelWidth, Height = bgra.PixelHeight };
                    p.Pixels = new byte[(long)p.Width * p.Height * 4];
                    bgra.CopyPixels(p.Pixels, p.Width * 4, 0);
                    for (long i = 3; i < p.Pixels.LongLength; i += 4)
                    {
                        if (p.Pixels[i] != 255) { p.HasAlpha = true; break; }
                    }
                    return p;
                }
            }
            catch (Exception e)
            {
                throw new EngineException(ExitCode.Read, "cannot read " + path, e);
            }
        }

        // Writes next to the target first, so a failure never leaves half a file behind.
        public static void Write(string path, int width, int height, byte[] pixels, bool alpha)
        {
            string temp = path + ".part";
            try
            {
                var source = BitmapSource.Create(width, height, 96, 96, alpha ? PixelFormats.Bgra32 : PixelFormats.Bgr24, null, pixels, width * (alpha ? 4 : 3));
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(source));
                using (var stream = File.Create(temp)) encoder.Save(stream);
                if (File.Exists(path)) File.Delete(path);
                File.Move(temp, path);
            }
            catch (Exception e)
            {
                try { File.Delete(temp); } catch (Exception) { }
                throw new EngineException(ExitCode.Write, "cannot write " + path, e);
            }
        }
    }

    // One ONNX Runtime session on one device, with pinned input and output buffers for one tile shape.
    sealed class Runner : IDisposable
    {
        public readonly string Key;         // model file, device, precision and tile shape
        public readonly Gpu Gpu;            // null on the CPU
        public readonly string Precision;   // "fp32" or "fp16"
        public readonly int TensorWidth, TensorHeight, Scale;
        public readonly float[] Input, Output;

        readonly InferenceSession session;
        readonly RunOptions runOptions = new RunOptions();
        GCHandle inputPin, outputPin;
        OrtValue inputValue, outputValue;
        string[] inputNames, outputNames;

        public bool OnGpu { get { return Gpu != null; } }

        public string Label
        {
            get
            {
                return Gpu == null ? "CPU, " + Precision : string.Format(CultureInfo.InvariantCulture, "{0} (DirectML #{1}, {2})", Gpu.Name, Gpu.DeviceId, Precision);
            }
        }

        public static string KeyFor(string modelFile, Gpu gpu, string precision, int width, int height, int scale)
        {
            Shape(ModelInfo.Of(modelFile), ref width, ref height);
            return string.Join("|", modelFile, gpu == null ? "cpu" : gpu.DeviceId.ToString(CultureInfo.InvariantCulture), precision,
                width.ToString(CultureInfo.InvariantCulture), height.ToString(CultureInfo.InvariantCulture), scale.ToString(CultureInfo.InvariantCulture));
        }

        // The tensor size for a tile: a model with a fixed input size keeps it, and named sizes are fixed to the tile,
        // so DirectML compiles one shape. One name for both height and width means a square input.
        static void Shape(ModelInfo info, ref int width, ref int height)
        {
            if (info.Dims[2] <= 0 && info.Dims[3] <= 0 && info.Symbols[2].Length > 0 && info.Symbols[2] == info.Symbols[3])
                width = height = Math.Max(width, height);
            if (info.Dims[2] > 0) height = info.Dims[2];
            if (info.Dims[3] > 0) width = info.Dims[3];
        }

        public Runner(string modelFile, Gpu gpu, string precision, int width, int height, int scale)
        {
            Gpu = gpu;
            Precision = precision;
            Scale = scale;
            Key = KeyFor(modelFile, gpu, precision, width, height, scale);
            ModelInfo info = ModelInfo.Of(modelFile);
            Shape(info, ref width, ref height);
            TensorHeight = height;
            TensorWidth = width;
            var options = new SessionOptions();
            try
            {
                options.LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR;
                options.GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL;
                if (info.Dims[0] <= 0 && info.Symbols[0].Length > 0) options.AddFreeDimensionOverrideByName(info.Symbols[0], 1);
                if (info.Dims[2] <= 0 && info.Symbols[2].Length > 0) options.AddFreeDimensionOverrideByName(info.Symbols[2], TensorHeight);
                if (info.Dims[3] <= 0 && info.Symbols[3].Length > 0 && info.Symbols[3] != info.Symbols[2]) options.AddFreeDimensionOverrideByName(info.Symbols[3], TensorWidth);
                if (gpu != null)
                {
                    options.EnableMemoryPattern = false;
                    options.ExecutionMode = ExecutionMode.ORT_SEQUENTIAL;
                    // The CPU only waits for the GPU here; do not let its threads spin.
                    options.AddSessionConfigEntry("session.intra_op.allow_spinning", "0");
                    options.AppendExecutionProvider_DML(gpu.DeviceId);
                }
                session = new InferenceSession(modelFile, options);
            }
            catch (Exception)
            {
                runOptions.Dispose();
                throw;
            }
            finally
            {
                options.Dispose();
            }
            try
            {
                inputNames = new[] { info.InputName };
                outputNames = new[] { info.OutputName };
                Input = new float[3L * TensorWidth * TensorHeight];
                Output = new float[3L * TensorWidth * scale * TensorHeight * scale];
                inputPin = GCHandle.Alloc(Input, GCHandleType.Pinned);
                outputPin = GCHandle.Alloc(Output, GCHandleType.Pinned);
                inputValue = OrtValue.CreateTensorValueWithData(OrtMemoryInfo.DefaultInstance, TensorElementType.Float,
                    new long[] { 1, 3, TensorHeight, TensorWidth }, inputPin.AddrOfPinnedObject(), Input.LongLength * 4);
                outputValue = OrtValue.CreateTensorValueWithData(OrtMemoryInfo.DefaultInstance, TensorElementType.Float,
                    new long[] { 1, 3, TensorHeight * scale, TensorWidth * scale }, outputPin.AddrOfPinnedObject(), Output.LongLength * 4);
            }
            catch (Exception)
            {
                Dispose();
                throw;
            }
        }

        public void Run()
        {
            session.Run(runOptions, inputNames, new[] { inputValue }, outputNames, new[] { outputValue });
        }

        public void Dispose()
        {
            // The OrtValues point into the pinned arrays, so they go first.
            if (inputValue != null) inputValue.Dispose();
            if (outputValue != null) outputValue.Dispose();
            inputValue = outputValue = null;
            if (inputPin.IsAllocated) inputPin.Free();
            if (outputPin.IsAllocated) outputPin.Free();
            runOptions.Dispose();
            if (session != null) session.Dispose();
        }
    }

    // What the engine needs to know about a model file, read once without optimizing the graph.
    sealed class ModelInfo
    {
        public string InputName, OutputName;
        public int[] Dims;          // N, C, H, W of the input; -1 where the size is named instead
        public string[] Symbols;    // those names, "" for fixed sizes
        public int Scale;           // from the "hoopics.scale" metadata, or 0

        static readonly Dictionary<string, ModelInfo> Cache = new Dictionary<string, ModelInfo>(StringComparer.OrdinalIgnoreCase);

        public static ModelInfo Of(string file)
        {
            ModelInfo info;
            if (Cache.TryGetValue(file, out info)) return info;
            var options = new SessionOptions();
            options.GraphOptimizationLevel = GraphOptimizationLevel.ORT_DISABLE_ALL;
            options.LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR;
            InferenceSession probe;
            try
            {
                probe = new InferenceSession(file, options);
            }
            catch (OnnxRuntimeException e)
            {
                throw new EngineException(ExitCode.Model, "ONNX Runtime cannot open " + file, e);
            }
            finally
            {
                options.Dispose();
            }
            using (probe)
            {
                if (probe.InputMetadata.Count != 1 || probe.OutputMetadata.Count != 1)
                    throw new EngineException(ExitCode.Model, "the model must have one input and one output: " + file);
                NodeMetadata input = probe.InputMetadata[probe.InputNames[0]];
                NodeMetadata output = probe.OutputMetadata[probe.OutputNames[0]];
                if (input.ElementType != typeof(float) || output.ElementType != typeof(float) || input.Dimensions.Length != 4 || (input.Dimensions[1] > 0 && input.Dimensions[1] != 3))
                    throw new EngineException(ExitCode.Model, "the model must take and return float32 RGB in NCHW layout: " + file);
                info = new ModelInfo { InputName = probe.InputNames[0], OutputName = probe.OutputNames[0], Dims = input.Dimensions, Symbols = input.SymbolicDimensions };
                string value;
                int n;
                if (probe.ModelMetadata.CustomMetadataMap.TryGetValue("hoopics.scale", out value) &&
                    int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n >= 1 && n <= 16) info.Scale = n;
            }
            Cache[file] = info;
            return info;
        }
    }

    // A GPU failure that stops the picture on that device. Lost: the device was reset or removed. OutOfMemory and
    // Garbage (a tile computed wrongly without an error) can come from tiles too big for the GPU.
    enum FailureKind { Lost, OutOfMemory, Garbage }

    sealed class DeviceFailure : Exception
    {
        public readonly FailureKind Kind;
        public readonly bool Simulated;
        public DeviceFailure(string message, FailureKind kind, Exception inner) : base(message, inner) { Kind = kind; }
        public DeviceFailure(string message, FailureKind kind, bool simulated) : base(message) { Kind = kind; Simulated = simulated; }
    }

    sealed class Upscaler
    {
        // Kept between jobs: the last model session, and what earlier jobs learned about the GPU.
        static Runner kept;
        static bool gpuLost;            // a GPU reset or hang; retrying it risks another, so the CPU does the rest
        static readonly Dictionary<string, int> tileLimits = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        // DirectML turns off Windows' GPU timeout. A tile is many short GPU steps, so the screen keeps drawing, but a
        // GPU that needs this long per tile makes the PC feel stuck; the next pictures then use smaller tiles.
        const double SlowTileMs = 4000;
        // The corner of a suspicious tile that the CPU computes again to see whether the GPU got it right.
        const int CheckSize = 48;
        // The smallest tile, padding included, that fp16 and fp32 are timed on.
        const int MinCalibrationSize = 160;
        // HOOPICS_ENGINE_FAULT=<kind>@<tile> makes the first device fail once at that tile, so tests can exercise the
        // fallbacks without a broken GPU. Kinds: "lost" (device removed), "oom" (out of memory), "garbage" (a black tile).
        static string fault = Environment.GetEnvironmentVariable("HOOPICS_ENGINE_FAULT");

        readonly Options options;
        Picture picture;
        int scale, contentWidth, contentHeight, tileIndex, tileCount;
        byte[] result;
        Runner primary, cpu;
        bool checkTiles = true;
        int slowTiles;

        public Upscaler(Options options) { this.options = options; }

        public static void Release()
        {
            if (kept != null) kept.Dispose();
            kept = null;
        }

        string ModelFile(string precision) { return options.Model + "." + precision + ".onnx"; }

        public void Run()
        {
            var watch = Stopwatch.StartNew();
            if (!File.Exists(ModelFile("fp32")) && !File.Exists(ModelFile("fp16")))
                throw new EngineException(ExitCode.Model, "model not found: " + options.Model + ".fp32.onnx / .fp16.onnx");
            Log.Progress(0);
            picture = Picture.Read(options.Input);
            scale = options.Scale > 0 ? options.Scale : ModelInfo.Of(File.Exists(ModelFile("fp32")) ? ModelFile("fp32") : ModelFile("fp16")).Scale;
            if (scale == 0) throw new EngineException(ExitCode.Model, "the model does not say its scale; pass -s");
            bool onCpu = options.Device == "cpu" || gpuLost;
            // What earlier pictures learned about this GPU's tile sizes; the CPU has no such limit.
            int limit;
            int tile = !onCpu && tileLimits.TryGetValue(options.Model, out limit) ? Math.Min(options.Tile, limit) : options.Tile;
            try
            {
                while (true)
                {
                    try
                    {
                        Process(tile, onCpu);
                        break;
                    }
                    catch (DeviceFailure e)
                    {
                        Drop(primary);
                        Drop(cpu);
                        primary = cpu = null;
                        if (onCpu && !e.Simulated) throw new EngineException(ExitCode.Inference, "the model failed on the CPU: " + e.Message, e);
                        // Out of graphics memory, or a wrong tile: try again with tiles half the size; the photo model's
                        // biggest tensor is about 1 GB at 384 px tiles. A lost device, or the same failure down at 64 px,
                        // and the CPU does the whole picture.
                        if (e.Kind != FailureKind.Lost && tile >= 128)
                        {
                            tile /= 2;
                            if (!onCpu) tileLimits[options.Model] = tile;
                            Log.Info("retry", e.Message + "; trying again with " + tile + " px tiles");
                            continue;
                        }
                        if (e.Kind != FailureKind.OutOfMemory && !e.Simulated) gpuLost = true;
                        Log.Info("fallback", "the GPU failed (" + e.Message + "); continuing on the CPU, which is slower");
                        onCpu = true;
                        tile = options.Tile;
                    }
                }
                if (picture.HasAlpha) AddAlpha();
                Picture.Write(options.Output, picture.Width * scale, picture.Height * scale, result, picture.HasAlpha);
                Log.Info("time", string.Format(CultureInfo.InvariantCulture, "{0:0.0} s for {1}x{2} -> {3}x{4} on the {5}",
                    watch.Elapsed.TotalSeconds, picture.Width, picture.Height, picture.Width * scale, picture.Height * scale, primary.OnGpu ? "GPU" : "CPU"));
                Log.Progress(100);
            }
            finally
            {
                // Keep the session for the next job; drop the CPU check session, which is cheap to make again.
                if (primary != null && primary != kept) { Drop(kept); kept = primary; }
                if (cpu != null && cpu != kept) cpu.Dispose();
                primary = cpu = null;
            }
        }

        static void Drop(Runner r)
        {
            if (r == null) return;
            if (r == kept) kept = null;
            r.Dispose();
        }

        void Process(int tile, bool onCpu)
        {
            int pad = options.Pad;
            primary = Open(Math.Min(tile, picture.Width) + 2 * pad, Math.Min(tile, picture.Height) + 2 * pad, onCpu);
            Log.Info(primary.OnGpu ? "gpu" : "cpu", primary.Label);
            contentWidth = Math.Min(primary.TensorWidth - 2 * pad, picture.Width);
            contentHeight = Math.Min(primary.TensorHeight - 2 * pad, picture.Height);
            if (contentWidth < 1 || contentHeight < 1) throw new EngineException(ExitCode.Model, "the model input is smaller than twice the padding");
            int tilesX = (picture.Width + contentWidth - 1) / contentWidth;
            int tilesY = (picture.Height + contentHeight - 1) / contentHeight;
            result = new byte[(long)picture.Width * scale * picture.Height * scale * (picture.HasAlpha ? 4 : 3)];
            tileCount = tilesX * tilesY;
            for (tileIndex = 0; tileIndex < tileCount; tileIndex++)
            {
                int x0 = TileStart(tileIndex % tilesX, contentWidth, picture.Width);
                int y0 = TileStart(tileIndex / tilesX, contentHeight, picture.Height);
                Store(RunTile(x0, y0), x0, y0);
                Log.Progress(99.0 * (tileIndex + 1) / tileCount);
            }
        }

        // Tiles step by the content size; the last one in a row or column moves back so it stays inside the picture.
        static int TileStart(int n, int size, int limit) { return Math.Min(n * size, limit - size); }

        Runner Open(int width, int height, bool onCpu)
        {
            if (onCpu) return OpenCpu(width, height);
            List<Gpu> gpus = Gpu.List();
            if (options.Device != "auto")
            {
                int id = int.Parse(options.Device, CultureInfo.InvariantCulture);
                gpus = gpus.FindAll(g => g.DeviceId == id);
                if (gpus.Count == 0) throw new EngineException(ExitCode.Usage, "no DirectML device #" + id);
            }
            foreach (Gpu gpu in gpus)
            {
                try
                {
                    return OpenGpu(gpu, width, height);
                }
                catch (Exception e)
                {
                    if (e is EngineException && ((EngineException)e).Code == ExitCode.Model) throw;
                    // Too big for this GPU's memory: Run() tries again with smaller tiles.
                    var ort = e as OnnxRuntimeException;
                    if (ort != null && IsOutOfMemory(ort) && width > 64 + 2 * options.Pad) throw new DeviceFailure(Hresult(ort), FailureKind.OutOfMemory, e);
                    Log.Info("skip", gpu.Name + ": " + Log.OneLine(e.Message, 300));
                }
            }
            if (gpus.Count > 0) Log.Info("fallback", "no GPU could run the model; using the CPU, which is slower");
            return OpenCpu(width, height);
        }

        Runner OpenCpu(int width, int height)
        {
            return Reuse(null, File.Exists(ModelFile("fp32")) ? "fp32" : "fp16", width, height);
        }

        // The session kept from the previous job when it fits, else a new one.
        Runner Reuse(Gpu gpu, string precision, int width, int height)
        {
            string file = ModelFile(precision);
            if (kept != null && kept.Key == Runner.KeyFor(file, gpu, precision, width, height, scale)) return kept;
            Drop(kept);
            try
            {
                return new Runner(file, gpu, precision, width, height, scale);
            }
            catch (OnnxRuntimeException e)
            {
                if (gpu == null) throw new EngineException(ExitCode.Model, "ONNX Runtime cannot open " + file, e);
                throw;
            }
        }

        // Picks fp16 or fp32 on this GPU. When both model files exist, the first picture measures both on its first
        // tile and remembers the faster one that gives the same result: fp16 is twice as fast on Intel Xe graphics
        // but slower on a GTX 1650 Ti, and a few GPUs compute fp16 wrongly.
        Runner OpenGpu(Gpu gpu, int width, int height)
        {
            bool has32 = File.Exists(ModelFile("fp32")), has16 = File.Exists(ModelFile("fp16"));
            string wanted = options.Precision;
            if (wanted == "auto" && !(has32 && has16)) wanted = has32 ? "fp32" : "fp16";
            if (wanted != "auto")
            {
                if (!File.Exists(ModelFile(wanted))) throw new EngineException(ExitCode.Model, "model not found: " + ModelFile(wanted));
                return Reuse(gpu, wanted, width, height);
            }
            string key = "precision|" + gpu.Key + "|" + Path.GetFileName(options.Model);
            string known = Choices.Get(options.ChoicesFile, key);
            if (known == "fp16" || known == "fp32") return Reuse(gpu, known, width, height);
            // A tiny picture says nothing about speed: use fp32 and measure on a bigger one.
            if (width < MinCalibrationSize || height < MinCalibrationSize) return Reuse(gpu, "fp32", width, height);
            Runner chosen = Calibrate(gpu, width, height);
            Choices.Set(options.ChoicesFile, key, chosen.Precision);
            return chosen;
        }

        Runner Calibrate(Gpu gpu, int width, int height)
        {
            Log.Info("calibrate", "measuring fp32 and fp16 on " + gpu.Name + " (first run only)");
            Drop(kept);
            Runner fp32 = null, fp16 = null, keep = null;
            try
            {
                fp32 = new Runner(ModelFile("fp32"), gpu, "fp32", width, height, scale);
                double time32 = TimeFirstTile(fp32), time16;
                try
                {
                    fp16 = new Runner(ModelFile("fp16"), gpu, "fp16", width, height, scale);
                    time16 = TimeFirstTile(fp16);
                }
                catch (OnnxRuntimeException e)
                {
                    Log.Info("calibrate", "fp16 failed (" + Log.OneLine(e.Message, 300) + ") -> fp32");
                    keep = fp32;
                    return keep;
                }
                double psnr = Psnr(fp32.Output, fp16.Output);
                bool fp16Wins = !double.IsNaN(psnr) && psnr >= 40 && time16 < 0.85 * time32;
                Log.Info("calibrate", string.Format(CultureInfo.InvariantCulture,
                    "fp32 {0:0} ms, fp16 {1:0} ms per tile, results {2:0.0} dB apart -> {3}", time32, time16, psnr, fp16Wins ? "fp16" : "fp32"));
                keep = fp16Wins ? fp16 : fp32;
                return keep;
            }
            finally
            {
                if (fp32 != null && fp32 != keep) fp32.Dispose();
                if (fp16 != null && fp16 != keep) fp16.Dispose();
            }
        }

        double TimeFirstTile(Runner r)
        {
            Fill(r, 0, 0);
            r.Run();   // the first run compiles the GPU shaders
            double best = double.MaxValue;
            for (int i = 0; i < 2; i++)
            {
                var watch = Stopwatch.StartNew();
                r.Run();
                best = Math.Min(best, watch.Elapsed.TotalMilliseconds);
            }
            return best;
        }

        // Runs one tile on the primary device and checks the result. A GPU failure ends the attempt with a
        // DeviceFailure; Run() then tries smaller tiles or the CPU.
        Runner RunTile(int x0, int y0)
        {
            Runner r = primary;
            Fill(r, x0, y0);
            var watch = Stopwatch.StartNew();
            try
            {
                r.Run();
            }
            catch (Exception e)
            {
                if (e is EngineException) throw;
                if (!r.OnGpu) throw new EngineException(ExitCode.Inference, "the model failed on the CPU", e);
                var ort = e as OnnxRuntimeException;
                throw new DeviceFailure(ort != null ? Hresult(ort) : Log.OneLine(e.Message, 300),
                    ort != null && IsOutOfMemory(ort) ? FailureKind.OutOfMemory : FailureKind.Lost, e);
            }
            if (r.OnGpu && watch.Elapsed.TotalMilliseconds > SlowTileMs && ++slowTiles == 2 && r.TensorWidth - 2 * options.Pad >= 128)
            {
                tileLimits[options.Model] = (r.TensorWidth - 2 * options.Pad) / 2;
                Log.Info("tile", string.Format(CultureInfo.InvariantCulture, "{0:0} ms per tile on this GPU; the next pictures use {1} px tiles",
                    watch.Elapsed.TotalMilliseconds, tileLimits[options.Model]));
            }
            bool injected = InjectFault();
            if (!checkTiles || Plausible(r, x0, y0)) return r;

            // The output does not look like an enlarged copy of the input. Compute the tile's top-left corner on the
            // CPU: if it agrees, the model simply changes this picture a lot, so stop checking; otherwise the GPU
            // computed the tile wrongly, which happens with tiles too big for it and after a driver reset.
            int checkWidth = Math.Min(contentWidth, CheckSize), checkHeight = Math.Min(contentHeight, CheckSize);
            if (cpu == null)
            {
                string precision = File.Exists(ModelFile("fp32")) ? "fp32" : "fp16";
                cpu = new Runner(ModelFile(precision), null, precision, checkWidth + 2 * options.Pad, checkHeight + 2 * options.Pad, scale);
            }
            Fill(cpu, x0, y0);
            cpu.Run();
            double psnr = Psnr(cpu, r, checkWidth, checkHeight);
            if (!double.IsNaN(psnr) && psnr >= 30 && !injected)
            {
                checkTiles = false;
                return r;
            }
            throw new DeviceFailure(string.Format(CultureInfo.InvariantCulture, "tile {0} of {1} came back wrong ({2:0.0} dB from the CPU's)",
                tileIndex + 1, tileCount, psnr), FailureKind.Garbage, injected);
        }

        bool InjectFault()
        {
            if (string.IsNullOrEmpty(fault)) return false;
            string[] parts = fault.Split('@');
            if (parts.Length != 2 || parts[1] != tileIndex.ToString(CultureInfo.InvariantCulture)) return false;
            fault = null;
            switch (parts[0])
            {
                case "garbage":
                    Array.Clear(primary.Output, 0, primary.Output.Length);
                    return true;
                case "lost":
                    throw new DeviceFailure("simulated DXGI_ERROR_DEVICE_REMOVED (887A0005)", FailureKind.Lost, true);
                case "oom":
                    throw new DeviceFailure("simulated E_OUTOFMEMORY (8007000E)", FailureKind.OutOfMemory, true);
                default:
                    throw new EngineException(ExitCode.Usage, "HOOPICS_ENGINE_FAULT must be lost, oom or garbage, @ a tile number");
            }
        }

        // DirectML reports device loss and memory errors only in the message text.
        static string Hresult(OnnxRuntimeException e)
        {
            foreach (string code in new[] { "887A0005", "887A0006", "887A0007", "887A0020", "8007000E" })
            {
                if (e.Message.IndexOf(code, StringComparison.OrdinalIgnoreCase) >= 0) return code + ": " + Log.OneLine(e.Message, 300);
            }
            return Log.OneLine(e.Message, 300);
        }

        static bool IsOutOfMemory(OnnxRuntimeException e)
        {
            return e.Message.IndexOf("8007000E", StringComparison.OrdinalIgnoreCase) >= 0 ||
                e.Message.IndexOf("out of memory", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // Copies the tile plus its padding into the input tensor as RGB in [0, 1]. Pixels beyond the picture repeat
        // its edge, like the Real-ESRGAN engine did.
        void Fill(Runner r, int x0, int y0)
        {
            int w = picture.Width, h = picture.Height, tw = r.TensorWidth, th = r.TensorHeight, pad = options.Pad;
            int plane = tw * th;
            byte[] px = picture.Pixels;
            float[] input = r.Input;
            const float k = 1f / 255f;
            for (int ty = 0; ty < th; ty++)
            {
                long row = (long)Clamp(y0 - pad + ty, 0, h - 1) * w * 4;
                int o = ty * tw;
                for (int tx = 0; tx < tw; tx++)
                {
                    long i = row + Clamp(x0 - pad + tx, 0, w - 1) * 4;
                    input[o + tx] = px[i + 2] * k;
                    input[plane + o + tx] = px[i + 1] * k;
                    input[2 * plane + o + tx] = px[i] * k;
                }
            }
        }

        static int Clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

        // True unless the tile is clearly broken: values that are not numbers, or an output that, shrunk back to the
        // input size, differs from the input by more than a fifth of the brightness range on average. An enlarged
        // picture shrinks back to almost exactly the input; a black or garbage tile does not.
        bool Plausible(Runner r, int x0, int y0)
        {
            int s = scale, pad = options.Pad, ow = r.TensorWidth * s, oplane = ow * r.TensorHeight * s;
            float[] output = r.Output;
            byte[] px = picture.Pixels;
            double diff = 0;
            float inv = 1f / (s * s);
            for (int y = 0; y < contentHeight; y++)
            {
                for (int x = 0; x < contentWidth; x++)
                {
                    long i = ((long)(y0 + y) * picture.Width + x0 + x) * 4;
                    for (int c = 0; c < 3; c++)
                    {
                        float sum = 0;
                        int origin = c * oplane + (pad + y) * s * ow + (pad + x) * s;
                        for (int dy = 0; dy < s; dy++)
                        {
                            int row = origin + dy * ow;
                            for (int dx = 0; dx < s; dx++) sum += output[row + dx];
                        }
                        float mean = sum * inv;
                        if (float.IsNaN(mean) || float.IsInfinity(mean)) return false;
                        diff += Math.Abs(mean - px[i + 2 - c] / 255f);
                    }
                }
            }
            return diff / (3.0 * contentWidth * contentHeight) <= 0.2;
        }

        // Peak signal-to-noise ratio between two runners' outputs over the top-left width x height of the tile content
        // (inside the padding), both in [0, 1]; NaN if either has values that are not numbers.
        double Psnr(Runner a, Runner b, int width, int height)
        {
            int s = scale, pad = options.Pad;
            int aw = a.TensorWidth * s, ap = aw * a.TensorHeight * s, bw = b.TensorWidth * s, bp = bw * b.TensorHeight * s;
            double sum = 0;
            for (int c = 0; c < 3; c++)
            {
                for (int y = pad * s; y < (pad + height) * s; y++)
                {
                    for (int x = pad * s; x < (pad + width) * s; x++)
                    {
                        double d = a.Output[c * ap + y * aw + x] - b.Output[c * bp + y * bw + x];
                        if (double.IsNaN(d) || double.IsInfinity(d)) return double.NaN;
                        sum += d * d;
                    }
                }
            }
            double mse = sum / (3.0 * width * s * height * s);
            return mse <= 1e-12 ? 120 : 10 * Math.Log10(1 / mse);
        }

        // Peak signal-to-noise ratio of b against a, both in [0, 1]; NaN if either has values that are not numbers.
        static double Psnr(float[] a, float[] b)
        {
            double sum = 0;
            for (long i = 0; i < a.LongLength; i++)
            {
                double d = a[i] - b[i];
                if (double.IsNaN(d) || double.IsInfinity(d)) return double.NaN;
                sum += d * d;
            }
            double mse = sum / a.LongLength;
            return mse <= 1e-12 ? 120 : 10 * Math.Log10(1 / mse);
        }

        // Copies the tile's enlarged content (without the padding) into the result as BGR or BGRA.
        void Store(Runner r, int x0, int y0)
        {
            int s = scale, pad = options.Pad, ow = r.TensorWidth * s, oplane = ow * r.TensorHeight * s;
            int bpp = picture.HasAlpha ? 4 : 3;
            long resultWidth = (long)picture.Width * s;
            float[] output = r.Output;
            for (int y = 0; y < contentHeight * s; y++)
            {
                int src = (pad * s + y) * ow + pad * s;
                long dst = ((y0 * s + y) * resultWidth + x0 * s) * bpp;
                for (int x = 0; x < contentWidth * s; x++, src++, dst += bpp)
                {
                    result[dst] = ToByte(output[2 * oplane + src]);
                    result[dst + 1] = ToByte(output[oplane + src]);
                    result[dst + 2] = ToByte(output[src]);
                }
            }
        }

        static byte ToByte(float v)
        {
            float x = v * 255f + 0.5f;
            return x <= 0 ? (byte)0 : x >= 255 ? (byte)255 : (byte)x;
        }

        // The model enlarges RGB only; transparency is enlarged with a bicubic filter (a = -0.75, as in OpenCV and
        // the Real-ESRGAN engine).
        void AddAlpha()
        {
            int w = picture.Width, h = picture.Height, s = scale, ow = w * s, oh = h * s;
            var alpha = new float[(long)w * h];
            for (long i = 0; i < alpha.LongLength; i++) alpha[i] = picture.Pixels[i * 4 + 3];
            // Horizontal pass, then vertical, with repeated edges.
            var wide = new float[(long)ow * h];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < ow; x++)
                {
                    double pos = (x + 0.5) / s - 0.5;
                    int baseX = (int)Math.Floor(pos);
                    double t = pos - baseX, v = 0;
                    for (int k = -1; k <= 2; k++) v += Cubic(k - t) * alpha[(long)y * w + Clamp(baseX + k, 0, w - 1)];
                    wide[(long)y * ow + x] = (float)v;
                }
            }
            for (int y = 0; y < oh; y++)
            {
                double pos = (y + 0.5) / s - 0.5;
                int baseY = (int)Math.Floor(pos);
                double t = pos - baseY;
                for (int x = 0; x < ow; x++)
                {
                    double v = 0;
                    for (int k = -1; k <= 2; k++) v += Cubic(k - t) * wide[(long)Clamp(baseY + k, 0, h - 1) * ow + x];
                    result[((long)y * ow + x) * 4 + 3] = ToByte((float)(v / 255));
                }
            }
        }

        static double Cubic(double x)
        {
            const double a = -0.75;
            x = Math.Abs(x);
            if (x < 1) return ((a + 2) * x - (a + 3)) * x * x + 1;
            if (x < 2) return ((a * x - 5 * a) * x + 8 * a) * x - 4 * a;
            return 0;
        }
    }

    // Remembered per-PC choices (fp16 or fp32 per GPU, driver and model), one "key=value" line each.
    static class Choices
    {
        public static string Get(string file, string key)
        {
            if (string.IsNullOrEmpty(file) || !File.Exists(file)) return null;
            try
            {
                foreach (string line in File.ReadAllLines(file))
                {
                    int eq = line.LastIndexOf('=');
                    if (eq > 0 && line.Substring(0, eq) == key) return line.Substring(eq + 1);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return null;
        }

        public static void Set(string file, string key, string value)
        {
            if (string.IsNullOrEmpty(file)) return;
            try
            {
                var lines = new List<string>();
                if (File.Exists(file)) lines.AddRange(File.ReadAllLines(file));
                lines.RemoveAll(l => l.StartsWith(key + "=", StringComparison.Ordinal));
                lines.Add(key + "=" + value);
                File.WriteAllLines(file, lines.ToArray());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
