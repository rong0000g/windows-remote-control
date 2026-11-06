using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Guided capture of the remote's raw HID reports while the voice key is held.
// Registers only the remote's own vendor and consumer collections, so no keyboard input is seen.
// A take ends when reports stop arriving, because the running script swallows the voice key.
// Output lines: "<take> <ms> <collection> <hex>" for reports, "# ..." for events.
// Usage: voicecap.exe <log file> <hardware id, such as VID&02568A_PID&9869>
static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] public struct RAWINPUTDEVICELIST { public IntPtr Device; public uint Type; }
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint GetRawInputDeviceList([In, Out] RAWINPUTDEVICELIST[] l, ref uint n, uint size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern uint GetRawInputDeviceInfo(IntPtr h, uint cmd, StringBuilder data, ref uint size);
    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW", SetLastError = true)] public static extern uint GetRawInputDeviceInfoBytes(IntPtr h, uint cmd, byte[] data, ref uint size);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint GetRawInputData(IntPtr h, uint cmd, byte[] data, ref uint size, uint headerSize);
    public const uint RIDI_DEVICENAME = 0x20000007, RIDI_DEVICEINFO = 0x2000000b, RID_INPUT = 0x10000003, RIDEV_INPUTSINK = 0x100;
}

class MainForm : Form {
    readonly string Match;
    const int HeaderSize = 24; // x64 RAWINPUTHEADER
    const int MinTakeMs = 1000;
    const int TakeGapMs = 500;
    readonly string[] prompts = {
        "按住语音键，说：今天天气不错，我们一起去公园散步。说完松开",
        "按住语音键，持续发“啊——”约 3 秒，再松开",
        "按住语音键，慢慢数：一、二、三、四、五、六、七、八、九、十。数完松开",
    };
    readonly Dictionary<IntPtr, string> remote = new Dictionary<IntPtr, string>();
    readonly Label promptLabel = new Label(), hintLabel = new Label();
    readonly StreamWriter log;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly Timer timeout = new Timer { Interval = 600000 };
    readonly Timer gap = new Timer { Interval = 100 };
    int index, reports;
    long takeStart = -1, lastReport;
    bool done;

    public MainForm(string logPath, string match) {
        Match = match.ToUpperInvariant();
        log = new StreamWriter(logPath, false, new UTF8Encoding(false));
        Text = "遥控器录音测试";
        ClientSize = new Size(640, 200);
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 10f);
        hintLabel.SetBounds(16, 10, 608, 26);
        hintLabel.Text = "共 3 次。遥控器对着嘴，距离和平时用投影仪语音时一样。";
        promptLabel.SetBounds(16, 44, 608, 140);
        promptLabel.Font = new Font("Microsoft YaHei UI", 17f, FontStyle.Bold);
        Controls.AddRange(new Control[] { hintLabel, promptLabel });
        timeout.Tick += (s, e) => { log.WriteLine("# TIMEOUT"); Close(); };
        timeout.Start();
        gap.Tick += (s, e) => CheckTakeEnd();
        gap.Start();
        ShowPrompt();
    }

    // Swallow every key so nothing from the remote reaches a control here.
    protected override bool ProcessCmdKey(ref Message m, Keys k) { return true; }

    void CheckTakeEnd() {
        if (done || takeStart < 0 || clock.ElapsedMilliseconds - lastReport < TakeGapMs) return;
        bool longEnough = lastReport - takeStart >= MinTakeMs;
        log.WriteLine("# " + (index + 1) + " END " + (lastReport - takeStart) + "ms reports=" + reports + (longEnough ? "" : " TOO_SHORT"));
        log.Flush();
        takeStart = -1;
        if (!longEnough) { hintLabel.Text = "按得太短了，这次不算，请按住再说一遍。"; return; }
        hintLabel.Text = "收到了。";
        if (++index >= prompts.Length) Finish(); else ShowPrompt();
    }

    void ShowPrompt() { promptLabel.Text = "第 " + (index + 1) + "/" + prompts.Length + " 次：\n" + prompts[index]; }

    static string DeviceName(IntPtr h) {
        uint n = 0;
        Native.GetRawInputDeviceInfo(h, Native.RIDI_DEVICENAME, null, ref n);
        var sb = new StringBuilder((int)n + 1);
        Native.GetRawInputDeviceInfo(h, Native.RIDI_DEVICENAME, sb, ref n);
        return sb.ToString();
    }

    static string Collection(string name) {
        int i = name.IndexOf("&Col", StringComparison.OrdinalIgnoreCase);
        return i >= 0 && i + 6 <= name.Length ? name.Substring(i + 1, 5) : "Col??";
    }

    string RemoteCollection(IntPtr h) {
        string c;
        if (remote.TryGetValue(h, out c)) return c;
        string name = DeviceName(h);
        c = name.ToUpperInvariant().Contains(Match) ? Collection(name) : "";
        remote[h] = c;
        return c;
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        var regs = new List<Native.RAWINPUTDEVICE>();
        uint count = 0, sz = (uint)Marshal.SizeOf(typeof(Native.RAWINPUTDEVICELIST));
        Native.GetRawInputDeviceList(null, ref count, sz);
        var devs = new Native.RAWINPUTDEVICELIST[count];
        Native.GetRawInputDeviceList(devs, ref count, sz);
        foreach (var d in devs) {
            string name = DeviceName(d.Device);
            if (!name.ToUpperInvariant().Contains(Match) || d.Type != 2) continue;
            uint n = 32;
            var info = new byte[32];
            Native.GetRawInputDeviceInfoBytes(d.Device, Native.RIDI_DEVICEINFO, info, ref n);
            ushort page = BitConverter.ToUInt16(info, 20), usage = BitConverter.ToUInt16(info, 22);
            log.WriteLine("# COLLECTION " + Collection(name) + " page=0x" + page.ToString("X4") + " usage=0x" + usage.ToString("X4"));
            if (!regs.Any(x => x.UsagePage == page && x.Usage == usage))
                // Usage 0 is only accepted as a whole-page registration (RIDEV_PAGEONLY).
                regs.Add(new Native.RAWINPUTDEVICE { UsagePage = page, Usage = usage, Flags = Native.RIDEV_INPUTSINK | (usage == 0 ? 0x20u : 0u), Target = Handle });
        }
        foreach (var r in regs) {
            bool ok = Native.RegisterRawInputDevices(new[] { r }, 1, (uint)Marshal.SizeOf(typeof(Native.RAWINPUTDEVICE)));
            log.WriteLine("# REGISTER page=0x" + r.UsagePage.ToString("X4") + " usage=0x" + r.Usage.ToString("X4") + " ok=" + ok);
        }
        log.Flush();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x00FF) OnRawInput(m.LParam); // WM_INPUT
        base.WndProc(ref m);
    }

    void OnRawInput(IntPtr h) {
        uint size = 0;
        Native.GetRawInputData(h, Native.RID_INPUT, null, ref size, HeaderSize);
        var buf = new byte[size];
        if (Native.GetRawInputData(h, Native.RID_INPUT, buf, ref size, HeaderSize) != size) return;
        uint type = BitConverter.ToUInt32(buf, 0);
        IntPtr device = new IntPtr(BitConverter.ToInt64(buf, 8));
        if (done || device == IntPtr.Zero) return;
        string collection = RemoteCollection(device);
        if (collection == "") return;
        long now = clock.ElapsedMilliseconds;
        if (type != 2) return;
        int len = (int)BitConverter.ToUInt32(buf, 24), cnt = (int)BitConverter.ToUInt32(buf, 28);
        for (int i = 0; i < cnt && 32 + (i + 1) * len <= buf.Length; i++)
            log.WriteLine((index + 1) + " " + now + " " + collection + " " + BitConverter.ToString(buf, 32 + i * len, len).Replace("-", ""));
        if (takeStart < 0) { takeStart = now; reports = 0; }
        lastReport = now;
        reports += cnt;
        hintLabel.Text = "正在接收：" + reports + " 个数据包";
    }

    void Finish() {
        done = true;
        log.WriteLine("# DONE");
        log.Flush();
        promptLabel.Text = "完成，窗口即将关闭";
        var close = new Timer { Interval = 1500 };
        close.Tick += (s, e) => Close();
        close.Start();
    }

    protected override void Dispose(bool d) { if (d) { log.Flush(); log.Dispose(); } base.Dispose(d); }
}

static class Program {
    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.Run(new MainForm(args[0], args[1]));
    }
}
