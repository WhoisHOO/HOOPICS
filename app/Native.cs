// Win32 and COM helpers for HOOPICS. Compiled at runtime by Add-Type, so it must stay C# 5.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Hoopics
{
    public sealed class MonitorRect
    {
        public string Id { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    // Only the leading vtable slots that HOOPICS calls are declared; their order must match shobjidl_core.h.
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDesktopWallpaper
    {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
        uint GetMonitorDevicePathCount();
        RECT GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(int position);
        int GetPosition();
    }

    [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
    internal class DesktopWallpaperCoClass
    {
    }

    public static class Desktop
    {
        private const int DWPOS_FILL = 4;

        // The rects come from Explorer, so they are real pixels whatever this process's DPI awareness is.
        // (A system-DPI-aware query reports a 100% monitor next to a 150% laptop as 1.5x too big.)
        public static MonitorRect[] GetMonitors()
        {
            var wallpaper = (IDesktopWallpaper)new DesktopWallpaperCoClass();
            try
            {
                var monitors = new List<MonitorRect>();
                uint count = wallpaper.GetMonitorDevicePathCount();
                for (uint i = 0; i < count; i++)
                {
                    string id = wallpaper.GetMonitorDevicePathAt(i);
                    RECT r;
                    try
                    {
                        r = wallpaper.GetMonitorRECT(id);
                    }
                    catch (Exception)
                    {
                        continue; // a remembered monitor that is not connected now
                    }
                    if (r.Right <= r.Left || r.Bottom <= r.Top)
                    {
                        continue;
                    }
                    monitors.Add(new MonitorRect { Id = id, Left = r.Left, Top = r.Top, Width = r.Right - r.Left, Height = r.Bottom - r.Top });
                }
                return monitors.ToArray();
            }
            finally
            {
                Marshal.ReleaseComObject(wallpaper);
            }
        }

        public static void SetWallpaper(string monitorId, string path)
        {
            var wallpaper = (IDesktopWallpaper)new DesktopWallpaperCoClass();
            try
            {
                wallpaper.SetPosition(DWPOS_FILL);
                wallpaper.SetWallpaper(monitorId, path);
            }
            finally
            {
                Marshal.ReleaseComObject(wallpaper);
            }
        }
    }

    public static class Dpi
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        // System-aware rather than per-monitor: WPF then renders sharply on the main screen, and Windows
        // still resizes the window correctly when it is dragged onto a screen with a different scale.
        public static void Enable()
        {
            SetProcessDPIAware();
        }
    }
}
