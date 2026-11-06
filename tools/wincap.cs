using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

// Read-only: renders every visible window of a process to a PNG with PrintWindow. Never activates anything.
// Usage: wincap.exe <process name without .exe> <output prefix>
static class Program {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    static int Main(string[] args) {
        SetProcessDPIAware();
        var pids = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName(args[0])) pids.Add((uint)p.Id);
        int n = 0;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            RECT r;
            if (!pids.Contains(pid) || !IsWindowVisible(h) || !GetWindowRect(h, out r)) return true;
            int w = r.R - r.L, hh = r.B - r.T;
            if (w < 50 || hh < 50) return true;
            var title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            string path = args[1] + (++n) + ".png";
            using (var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb))
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr dc = g.GetHdc();
                bool ok = PrintWindow(h, dc, 2); // PW_RENDERFULLCONTENT
                g.ReleaseHdc(dc);
                bmp.Save(path, ImageFormat.Png);
                Console.WriteLine(path + " hwnd=" + h + " pid=" + pid + " " + r.L + "," + r.T + " " + w + "x" + hh + " ok=" + ok + " [" + title + "]");
            }
            return true;
        }, IntPtr.Zero);
        return 0;
    }
}
