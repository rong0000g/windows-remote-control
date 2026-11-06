using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Guided raw-input logger. Records only input from the remote's own HID collections;
// the physical keyboard is registered by the same usage but its events are discarded.
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
    public string[] prompts = { "↑", "↓", "←", "→", "OK", "返回", "菜单(三条横线)", "主页(小房子)", "设置(齿轮)",
        "音量 +", "音量 -", "静音", "F+", "F-", "F-和F+中间的键", "右上角信号源键", "语音键(短按一下,不用说话)" };
    readonly Dictionary<IntPtr, bool> isRemote = new Dictionary<IntPtr, bool>();
    readonly Label promptLabel = new Label(), hintLabel = new Label();
    readonly ListBox list = new ListBox();
    readonly Button skip = new Button();
    readonly Timer quiet = new Timer { Interval = 800 };
    readonly StreamWriter log;
    readonly List<string> captured = new List<string>();
    int index;

    public MainForm(string logPath, string match, string[] overridePrompts) {
        Match = match.ToUpperInvariant();
        if (overridePrompts.Length > 0) prompts = overridePrompts;
        log = new StreamWriter(logPath, false, new UTF8Encoding(false)) { AutoFlush = true };
        Text = "遥控器按键测试";
        ClientSize = new Size(560, 460);
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 10f);
        hintLabel.SetBounds(16, 10, 528, 26);
        hintLabel.Text = "按屏幕提示的键，每个按一下。不要按电源键。这个窗口只记录遥控器。";
        promptLabel.SetBounds(16, 40, 528, 70);
        promptLabel.Font = new Font("Microsoft YaHei UI", 22f, FontStyle.Bold);
        list.SetBounds(16, 116, 528, 280);
        list.TabStop = false;
        skip.SetBounds(16, 408, 200, 36);
        skip.Text = "这个键没有反应，跳过";
        skip.TabStop = false;
        skip.Click += (s, e) => Commit(true);
        quiet.Tick += (s, e) => Commit(false);
        Controls.AddRange(new Control[] { hintLabel, promptLabel, list, skip });
        ShowPrompt();
    }

    // Swallow every key so OK/Enter and arrows cannot reach another window's input box or this form's button.
    protected override bool ProcessCmdKey(ref Message m, Keys k) { return true; }

    void ShowPrompt() { promptLabel.Text = "请按：" + prompts[index] + "  (" + (index + 1) + "/" + prompts.Length + ")"; }

    void Commit(bool skipped) {
        quiet.Stop();
        if (!skipped && captured.Count == 0) return;
        string body = skipped && captured.Count == 0 ? "NO EVENT" : string.Join(" ; ", captured);
        log.WriteLine("[" + prompts[index] + "] " + body);
        list.Items.Add(prompts[index] + "  →  " + (body.Length > 58 ? body.Substring(0, 58) + "…" : body));
        list.TopIndex = list.Items.Count - 1;
        captured.Clear();
        if (++index >= prompts.Length) {
            log.WriteLine("=== DONE ===");
            promptLabel.Text = "全部完成，窗口即将关闭";
            skip.Enabled = false;
            var close = new Timer { Interval = 2500 };
            close.Tick += (s, e) => Close();
            close.Start();
            index = prompts.Length - 1;
            done = true;
            return;
        }
        ShowPrompt();
    }
    bool done;

    bool IsRemote(IntPtr h) {
        bool r;
        if (isRemote.TryGetValue(h, out r)) return r;
        r = DeviceName(h).ToUpperInvariant().Contains(Match);
        isRemote[h] = r;
        return r;
    }

    static string DeviceName(IntPtr h) {
        uint n = 0;
        Native.GetRawInputDeviceInfo(h, Native.RIDI_DEVICENAME, null, ref n);
        var sb = new StringBuilder((int)n + 1);
        Native.GetRawInputDeviceInfo(h, Native.RIDI_DEVICENAME, sb, ref n);
        return sb.ToString();
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        var regs = new List<Native.RAWINPUTDEVICE>();
        regs.Add(new Native.RAWINPUTDEVICE { UsagePage = 1, Usage = 6, Flags = Native.RIDEV_INPUTSINK, Target = Handle });
        uint count = 0, sz = (uint)Marshal.SizeOf(typeof(Native.RAWINPUTDEVICELIST));
        Native.GetRawInputDeviceList(null, ref count, sz);
        var devs = new Native.RAWINPUTDEVICELIST[count];
        Native.GetRawInputDeviceList(devs, ref count, sz);
        foreach (var d in devs) {
            string name = DeviceName(d.Device);
            if (!name.ToUpperInvariant().Contains(Match)) continue;
            uint n = 32;
            var info = new byte[32];
            Native.GetRawInputDeviceInfoBytes(d.Device, Native.RIDI_DEVICEINFO, info, ref n);
            ushort page = 1, usage = 6;
            if (d.Type == 2) { page = BitConverter.ToUInt16(info, 20); usage = BitConverter.ToUInt16(info, 22); }
            log.WriteLine("COLLECTION type=" + d.Type + " usagePage=0x" + page.ToString("X4") + " usage=0x" + usage.ToString("X4") + " name=" + name);
            if (!regs.Any(x => x.UsagePage == page && x.Usage == usage))
                // Usage 0 is only accepted as a whole-page registration (RIDEV_PAGEONLY).
                regs.Add(new Native.RAWINPUTDEVICE { UsagePage = page, Usage = usage, Flags = Native.RIDEV_INPUTSINK | (usage == 0 ? 0x20u : 0u), Target = Handle });
        }
        if (regs.Count < 2) log.WriteLine("WARNING: remote HID collections not found");
        // Register one at a time so a rejected vendor collection cannot take the keyboard down with it.
        int failed = 0;
        foreach (var r in regs) {
            bool ok = Native.RegisterRawInputDevices(new[] { r }, 1, (uint)Marshal.SizeOf(typeof(Native.RAWINPUTDEVICE)));
            if (!ok) failed++;
            log.WriteLine("REGISTER page=0x" + r.UsagePage.ToString("X4") + " usage=0x" + r.Usage.ToString("X4") + " ok=" + ok + (ok ? "" : " err=" + Marshal.GetLastWin32Error()));
        }
        hintLabel.Text = failed == 0 ? "按屏幕提示的键，每个按一下。不要按电源键。这个窗口只记录遥控器。"
            : "有 " + failed + " 个通道注册失败，其余仍可记录。按提示按键，不要按电源键。";
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
        if (done) return;
        string line;
        if (device == IntPtr.Zero) {
            // Media keys translated by Windows can arrive without a device handle; keep only those, never text keys.
            if (type != 1) return;
            ushort zvk = BitConverter.ToUInt16(buf, 30), zflags = BitConverter.ToUInt16(buf, 26);
            bool media = zvk == 0x1B || (zvk >= 0xA6 && zvk <= 0xB7);
            if (!media) return;
            line = "KB(no-device) " + ((zflags & 1) != 0 ? "up" : "down") + " vk=0x" + zvk.ToString("X2") + " sc=0x" + BitConverter.ToUInt16(buf, 24).ToString("X2");
            if (captured.Count < 40) captured.Add(line);
            quiet.Stop();
            quiet.Start();
            return;
        }
        if (!IsRemote(device)) return;
        if (type == 1) {
            ushort make = BitConverter.ToUInt16(buf, 24), flags = BitConverter.ToUInt16(buf, 26), vk = BitConverter.ToUInt16(buf, 30);
            line = "KB " + ((flags & 1) != 0 ? "up" : "down") + " vk=0x" + vk.ToString("X2") + " sc=0x" + make.ToString("X2") + ((flags & 2) != 0 ? " E0" : "") + ((flags & 4) != 0 ? " E1" : "");
        } else if (type == 2) {
            int len = (int)BitConverter.ToUInt32(buf, 24), cnt = (int)BitConverter.ToUInt32(buf, 28);
            int total = Math.Min(len * cnt, buf.Length - 32);
            line = "HID len=" + len + " data=" + BitConverter.ToString(buf, 32, Math.Min(total, 24));
        } else return;
        if (captured.Count < 40) captured.Add(line);
        quiet.Stop();
        quiet.Start();
    }

    protected override void Dispose(bool d) { if (d) log.Dispose(); base.Dispose(d); }
}

static class Program {
    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        // 用法：keylog.exe <日志文件> <硬件 ID，如 VID&02568A_PID&9869> [按键提示...]
        Application.Run(new MainForm(args[0], args[1], args.Skip(2).ToArray()));
    }
}
