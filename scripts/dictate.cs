using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Speech.Synthesis;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// 语音输入程序，由 remote-control.ahk 启动。声音来自遥控器自带的麦克风，不用电脑上的录音设备。
// 按住语音键时，遥控器通过 HID 厂商集合发送 SBC 音频，这里用 Raw Input 接收。数据流停止就算说完。
// 识别默认用本机 SenseVoice：asr_worker.py 第一次用时才加载模型，闲置一段时间后退出以释放内存。
// 配了云端 API 和 Key 时改为上传识别，失败时退回本机识别。
// 结果用 WM_COPYDATA 发回脚本：S=开始 P=识别中 T=最终文字 W=云端失败 L=写日志 D=结束（可带提示）E=错误。
// 用法：dictate.exe <脚本窗口句柄> --config 配置.ini --key 密钥文件
//       dictate.exe --synth 文字 输出.wav          生成测试语音
//       dictate.exe --recognize 音频.wav 结果.txt  把本机识别结果写入文件
//       dictate.exe --sbc 抓包日志 输出前缀         把 voicecap 的抓包解码成 wav，每段一个文件
static class Program {
    const string RemoteMatch = "VID&02568A_PID&9869";
    const ushort AudioUsagePage = 0xFF01, AudioUsage = 0x0001;
    const int TakeGapMs = 400;
    const int MinFrames = 63;         // 约 0.5 秒，更短的算误触
    const int MaxFrames = 125 * 180;  // 约 3 分钟
    const int WorkerIdleMs = 300000;
    const string ModelDirName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17";
    const string ZhPrompt = "以下是普通话的句子，使用简体中文，并加上标点符号。";

    [StructLayout(LayoutKind.Sequential)]
    struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }
    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, ref COPYDATASTRUCT lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr h, uint cmd, StringBuilder data, ref uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, byte[] data, ref uint size, uint headerSize);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetPrivateProfileString(string section, string key, string def, StringBuilder value, int size, string file);

    static IntPtr target;
    static string baseUrl, model, language, apiKey;
    static bool cloud;
    static readonly Dictionary<IntPtr, bool> isRemote = new Dictionary<IntPtr, bool>();
    static List<byte[]> frames;
    static int lastFrameTick;
    static readonly object workerLock = new object();
    static Process worker;
    static int workerUsedTick;

    class RemoteWindow : NativeWindow {
        public RemoteWindow() { CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); } // HWND_MESSAGE
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x00FF) OnRawInput(m.LParam); // WM_INPUT
            base.WndProc(ref m);
        }
    }

    static void Post(string kind, string text) {
        string data = kind + text;
        IntPtr mem = Marshal.StringToHGlobalUni(data);
        try {
            var cds = new COPYDATASTRUCT { dwData = IntPtr.Zero, cbData = (data.Length + 1) * 2, lpData = mem };
            IntPtr result;
            SendMessageTimeout(target, 0x4A, IntPtr.Zero, ref cds, 2, 3000, out result);
        } finally {
            Marshal.FreeHGlobal(mem);
        }
    }

    static string ReadIni(string file, string key) {
        var sb = new StringBuilder(1024);
        GetPrivateProfileString("VoiceApi", key, "", sb, sb.Capacity, file);
        return sb.ToString().Trim();
    }

    // 密钥只允许发给 https 地址，本机地址除外（用于测试）。
    static bool UrlAllowed(string url) {
        return url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            || url.StartsWith("http://127.0.0.1", StringComparison.OrdinalIgnoreCase);
    }

    static void LoadConfig(string configPath, string keyPath) {
        cloud = false;
        if (configPath == null || !File.Exists(configPath)) return;
        string provider = ReadIni(configPath, "provider");
        baseUrl = ReadIni(configPath, "baseUrl").TrimEnd('/');
        model = ReadIni(configPath, "model");
        language = ReadIni(configPath, "language");
        if (provider == "" || provider == "本机离线" || baseUrl == "" || model == "" || !UrlAllowed(baseUrl)) return;
        if (keyPath == null || !File.Exists(keyPath)) return;
        try {
            byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(keyPath), null, DataProtectionScope.CurrentUser);
            apiKey = Encoding.UTF8.GetString(plain).Trim();
            cloud = apiKey != "";
        } catch {
            cloud = false;
        }
    }

    // ===== 接收遥控器音频 =====

    static bool IsRemoteDevice(IntPtr h) {
        bool r;
        if (isRemote.TryGetValue(h, out r)) return r;
        uint n = 0;
        GetRawInputDeviceInfo(h, 0x20000007, null, ref n); // RIDI_DEVICENAME
        var sb = new StringBuilder((int)n + 1);
        GetRawInputDeviceInfo(h, 0x20000007, sb, ref n);
        r = sb.ToString().ToUpperInvariant().Contains(RemoteMatch);
        isRemote[h] = r;
        return r;
    }

    static void OnRawInput(IntPtr h) {
        const uint RID_INPUT = 0x10000003;
        uint header = (uint)(8 + 2 * IntPtr.Size), size = 0;
        GetRawInputData(h, RID_INPUT, null, ref size, header);
        var buf = new byte[size];
        if (GetRawInputData(h, RID_INPUT, buf, ref size, header) != size) return;
        if (BitConverter.ToUInt32(buf, 0) != 2) return; // RIM_TYPEHID
        IntPtr device = IntPtr.Size == 8 ? new IntPtr(BitConverter.ToInt64(buf, 8)) : new IntPtr(BitConverter.ToInt32(buf, 8));
        if (device == IntPtr.Zero || !IsRemoteDevice(device)) return;
        int len = (int)BitConverter.ToUInt32(buf, (int)header), count = (int)BitConverter.ToUInt32(buf, (int)header + 4);
        int start = (int)header + 8;
        if (len != Sbc.FrameBytes + 1) return;
        for (int i = 0; i < count && start + (i + 1) * len <= buf.Length; i++) {
            int offset = start + i * len;
            if (buf[offset] != 0xFD) continue;
            var frame = new byte[Sbc.FrameBytes];
            Buffer.BlockCopy(buf, offset + 1, frame, 0, Sbc.FrameBytes);
            AddFrame(frame);
        }
    }

    static void AddFrame(byte[] frame) {
        if (frames == null) {
            frames = new List<byte[]>();
            Post("S", "");
            // 边说边加载模型，松开时通常已经就绪。
            if (!cloud) new Thread(Preload) { IsBackground = true }.Start();
        }
        if (frames.Count < MaxFrames) frames.Add(frame);
        lastFrameTick = Environment.TickCount;
    }

    static void Preload() {
        try {
            lock (workerLock) EnsureWorker();
        } catch {
            // 真正识别时还会再试一次并报告错误。
        }
    }

    static void OnTimer(object sender, EventArgs e) {
        if (!IsWindow(target)) {
            Application.Exit();
            return;
        }
        if (frames != null && Environment.TickCount - lastFrameTick >= TakeGapMs) {
            var take = frames;
            frames = null;
            Post("L", "音频 " + take.Count + " 帧，约 " + (take.Count * 8) + " 毫秒");
            if (take.Count < MinFrames) {
                Post("D", "太短了：按住语音键说话，说完再松开");
                return;
            }
            Post("P", "");
            new Thread(() => Transcribe(take)) { IsBackground = true }.Start();
        }
        if (Monitor.TryEnter(workerLock)) {
            try {
                if (worker != null && Environment.TickCount - workerUsedTick > WorkerIdleMs) StopWorker();
            } finally {
                Monitor.Exit(workerLock);
            }
        }
    }

    // ===== 识别 =====

    static void Transcribe(List<byte[]> take) {
        string file = Path.Combine(Path.GetTempPath(), "remote-dictate-" + Guid.NewGuid().ToString("N") + ".wav");
        string ending = "";
        try {
            WriteWav(file, Sbc.Decode(take));
            string text;
            if (cloud) {
                try {
                    text = CallApi(file);
                } catch (Exception ex) {
                    Post("W", DescribeError(ex));
                    text = RecognizeLocal(file);
                }
            } else {
                text = RecognizeLocal(file);
            }
            // 没说话时模型可能只返回一个句号，不要打进输入框。
            Post("L", "识别结果 " + (text == null ? 0 : text.Trim().Length) + " 字");
            if (HasWords(text)) Post("T", text.Trim());
            else ending = "没听清，再说一遍";
        } catch (Exception ex) {
            Post("E", ex.Message);
        } finally {
            try { File.Delete(file); } catch { }
            Post("D", ending);
        }
    }

    static bool HasWords(string text) {
        if (text == null) return false;
        foreach (char c in text)
            if (char.IsLetterOrDigit(c)) return true;
        return false;
    }

    static void EnsureWorker() {
        if (worker != null && !worker.HasExited) return;
        string dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "asr");
        var info = new ProcessStartInfo("python") {
            Arguments = "-I \"" + Path.Combine(dir, "asr_worker.py") + "\" \"" + Path.Combine(dir, ModelDirName) + "\" \"" + Path.Combine(dir, "pylib") + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        worker = Process.Start(info);
        workerUsedTick = Environment.TickCount;
        string line = ReadWorkerLine();
        if (line != "READY") {
            StopWorker();
            throw new InvalidOperationException("模型加载失败：" + line);
        }
    }

    static string ReadWorkerLine() {
        while (true) {
            string line = worker.StandardOutput.ReadLine();
            if (line == null) return "进程已退出";
            if (line == "READY" || line.StartsWith("TEXT ") || line == "TEXT" || line.StartsWith("ERR ")) return line;
        }
    }

    static void StopWorker() {
        if (worker == null) return;
        try {
            worker.StandardInput.Close();
            if (!worker.WaitForExit(3000)) worker.Kill();
        } catch {
            // 进程已经退出。
        }
        worker = null;
    }

    static string RecognizeLocal(string file) {
        lock (workerLock) {
            EnsureWorker();
            byte[] path = Encoding.UTF8.GetBytes(file + "\n");
            worker.StandardInput.BaseStream.Write(path, 0, path.Length);
            worker.StandardInput.BaseStream.Flush();
            string line = ReadWorkerLine();
            workerUsedTick = Environment.TickCount;
            if (line.StartsWith("TEXT")) return line.Length > 5 ? line.Substring(5) : "";
            StopWorker();
            throw new InvalidOperationException("识别失败：" + line);
        }
    }

    static void WriteWav(string path, short[] pcm) {
        using (var w = new BinaryWriter(File.Create(path))) {
            int bytes = pcm.Length * 2;
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(36 + bytes);
            w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            w.Write(16);
            w.Write((short)1);
            w.Write((short)1);
            w.Write(Sbc.SampleRate);
            w.Write(Sbc.SampleRate * 2);
            w.Write((short)2);
            w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(bytes);
            foreach (short s in pcm) w.Write(s);
        }
    }

    // 只报告状态码，不带响应内容，避免把 Key 片段写进日志。
    static string DescribeError(Exception ex) {
        var web = ex as WebException;
        if (web != null && web.Response is HttpWebResponse)
            return "HTTP " + (int)((HttpWebResponse)web.Response).StatusCode;
        return web != null ? web.Status.ToString() : ex.GetType().Name;
    }

    static string CallApi(string file) {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        string boundary = "----remote" + Guid.NewGuid().ToString("N");
        var request = (HttpWebRequest)WebRequest.Create(baseUrl + "/audio/transcriptions");
        request.Method = "POST";
        request.Timeout = 60000;
        request.ReadWriteTimeout = 60000;
        request.ContentType = "multipart/form-data; boundary=" + boundary;
        request.Headers["Authorization"] = "Bearer " + apiKey;
        using (var body = request.GetRequestStream()) {
            WriteField(body, boundary, "model", model);
            WriteField(body, boundary, "response_format", "json");
            if (language != "") WriteField(body, boundary, "language", language);
            if (language == "zh") WriteField(body, boundary, "prompt", ZhPrompt);
            WriteRaw(body, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
            byte[] audio = File.ReadAllBytes(file);
            body.Write(audio, 0, audio.Length);
            WriteRaw(body, "\r\n--" + boundary + "--\r\n");
        }
        using (var response = request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
            var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            object text;
            if (!json.TryGetValue("text", out text) || text == null) return "";
            // SenseVoice 可能在文字前带 <|zh|> 这类标签。
            return Regex.Replace(text.ToString(), "<\\|[^|]*\\|>", "").Trim();
        }
    }

    static void WriteRaw(Stream s, string text) {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        s.Write(bytes, 0, bytes.Length);
    }

    static void WriteField(Stream s, string boundary, string name, string value) {
        WriteRaw(s, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value + "\r\n");
    }

    static string ArgAfter(string[] args, string flag) {
        int i = Array.IndexOf(args, flag);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    [STAThread]
    static int Main(string[] args) {
        if (args.Length >= 3 && args[0] == "--synth") return Synth(args[1], args[2]);
        if (args.Length >= 3 && args[0] == "--sbc") return DecodeLog(args[1], args[2]);
        if (args.Length >= 3 && args[0] == "--recognize") {
            File.WriteAllText(args[2], RecognizeLocal(args[1]), new UTF8Encoding(false));
            lock (workerLock) StopWorker();
            return 0;
        }
        if (args.Length < 1) return 2;
        target = new IntPtr(Convert.ToInt64(args[0]));
        LoadConfig(ArgAfter(args, "--config"), ArgAfter(args, "--key"));

        var window = new RemoteWindow();
        var device = new RAWINPUTDEVICE { UsagePage = AudioUsagePage, Usage = AudioUsage, Flags = 0x100, Target = window.Handle }; // RIDEV_INPUTSINK
        if (!RegisterRawInputDevices(new[] { device }, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) {
            Post("E", "无法接收遥控器音频");
            return 1;
        }
        var timer = new System.Windows.Forms.Timer { Interval = 100 };
        timer.Tick += OnTimer;
        timer.Start();
        Application.Run();
        lock (workerLock) StopWorker();
        return 0;
    }

    static int Synth(string text, string path) {
        using (var s = new SpeechSynthesizer()) {
            s.SelectVoiceByHints(VoiceGender.NotSet, VoiceAge.NotSet, 0, new CultureInfo("zh-CN"));
            s.SetOutputToWaveFile(path);
            s.Speak(text);
        }
        return 0;
    }

    static int DecodeLog(string log, string prefix) {
        var take = new List<byte[]>();
        long prev = -1;
        int n = 0;
        foreach (string line in File.ReadLines(log)) {
            if (line.StartsWith("#")) continue;
            string[] parts = line.Split(' ');
            if (parts.Length < 4 || parts[3].Length != (Sbc.FrameBytes + 1) * 2) continue;
            long t = long.Parse(parts[1]);
            if (prev >= 0 && t - prev > 300 && take.Count > 0) {
                WriteWav(prefix + (++n) + ".wav", Sbc.Decode(take));
                take.Clear();
            }
            prev = t;
            var frame = new byte[Sbc.FrameBytes];
            for (int i = 0; i < Sbc.FrameBytes; i++)
                frame[i] = Convert.ToByte(parts[3].Substring(2 + i * 2, 2), 16);
            take.Add(frame);
        }
        if (take.Count > 0) WriteWav(prefix + (++n) + ".wav", Sbc.Decode(take));
        return 0;
    }
}

// 遥控器的音频是去掉帧头和校验的 SBC：16 kHz、单声道、8 子带、16 块、bitpool 8、loudness 分配。
// 每帧 20 字节，前 4 字节是 8 个子带的比例因子，后 16 字节是采样。
static class Sbc {
    public const int FrameBytes = 20, SampleRate = 16000;
    const int Subbands = 8, Blocks = 16, Bitpool = 8, Taps = 80;
    const double OutputPeak = 30000.0;
    static readonly int[] Offset16k = { -2, 0, 0, 0, 0, 0, 0, 1 };
    static readonly double[] HalfWindow = {
        0.0, 1.56575398e-04, 3.43256425e-04, 5.54620202e-04, 8.23919506e-04, 1.13992507e-03,
        1.47640169e-03, 1.78371725e-03, 2.01182542e-03, 2.10371989e-03, 1.99454554e-03,
        1.61656283e-03, 9.02154502e-04, -1.78805361e-04, -1.64973098e-03, -3.49717454e-03,
        -5.65949473e-03, -8.02941163e-03, -1.04584443e-02, -1.27472335e-02, -1.46525263e-02,
        -1.59045603e-02, -1.62208471e-02, -1.53184106e-02, -1.29371806e-02, -8.85757540e-03,
        -2.92408442e-03, 4.91578024e-03, 1.46404076e-02, 2.61098752e-02, 3.90751381e-02,
        5.31873032e-02, 6.79989431e-02, 8.29847578e-02, 9.75753918e-02, 1.11196689e-01,
        1.23264548e-01, 1.33264415e-01, 1.40753505e-01, 1.45389847e-01, 1.46955068e-01 };
    static readonly double[,] Synthesis = BuildSynthesis();

    static double[,] BuildSynthesis() {
        var table = new double[Subbands, Taps];
        for (int k = 0; k < Subbands; k++)
            for (int n = 0; n < Taps; n++) {
                double h = n <= 40 ? HalfWindow[n] : HalfWindow[80 - n];
                table[k, n] = Subbands * h * Math.Cos((k + 0.5) * (n + 4) * Math.PI / Subbands);
            }
        return table;
    }

    static int[] Allocate(int[] scale) {
        var need = new int[Subbands];
        int max = int.MinValue;
        for (int sb = 0; sb < Subbands; sb++) {
            if (scale[sb] == 0) {
                need[sb] = -5;
            } else {
                int loudness = scale[sb] - Offset16k[sb];
                need[sb] = loudness > 0 ? loudness / 2 : loudness;
            }
            max = Math.Max(max, need[sb]);
        }
        int bitslice = max + 1, bitcount = 0, slicecount = 0;
        do {
            bitslice--;
            bitcount += slicecount;
            slicecount = 0;
            for (int sb = 0; sb < Subbands; sb++) {
                if (need[sb] > bitslice + 1 && need[sb] < bitslice + 16) slicecount++;
                else if (need[sb] == bitslice + 1) slicecount += 2;
            }
        } while (bitcount + slicecount < Bitpool);
        if (bitcount + slicecount == Bitpool) {
            bitcount += slicecount;
            bitslice--;
        }
        var bits = new int[Subbands];
        for (int sb = 0; sb < Subbands; sb++)
            bits[sb] = need[sb] < bitslice + 2 ? 0 : Math.Min(need[sb] - bitslice, 16);
        for (int sb = 0; bitcount < Bitpool && sb < Subbands; sb++) {
            if (bits[sb] >= 2 && bits[sb] < 16) {
                bits[sb]++;
                bitcount++;
            } else if (need[sb] == bitslice + 1 && Bitpool > bitcount + 1) {
                bits[sb] = 2;
                bitcount += 2;
            }
        }
        for (int sb = 0; bitcount < Bitpool && sb < Subbands; sb++) {
            if (bits[sb] < 16) {
                bits[sb]++;
                bitcount++;
            }
        }
        return bits;
    }

    public static short[] Decode(List<byte[]> frames) {
        var output = new double[frames.Count * Blocks * Subbands + Taps];
        var scale = new int[Subbands];
        int block = 0;
        foreach (byte[] f in frames) {
            for (int i = 0; i < 4; i++) {
                scale[i * 2] = f[i] >> 4;
                scale[i * 2 + 1] = f[i] & 15;
            }
            int[] bits = Allocate(scale);
            int bitPos = 32;
            for (int b = 0; b < Blocks; b++, block++) {
                for (int sb = 0; sb < Subbands; sb++) {
                    int n = bits[sb];
                    if (n == 0) continue;
                    int value = 0;
                    for (int i = 0; i < n; i++, bitPos++)
                        value = (value << 1) | ((f[bitPos >> 3] >> (7 - (bitPos & 7))) & 1);
                    double sample = Math.Pow(2, scale[sb] + 1) * ((value * 2 + 1) / (double)((1 << n) - 1) - 1);
                    int start = block * Subbands;
                    for (int t = 0; t < Taps; t++)
                        output[start + t] += sample * Synthesis[sb, t];
                }
            }
        }
        double peak = 1.0;
        foreach (double v in output) peak = Math.Max(peak, Math.Abs(v));
        double gain = Math.Min(1.0, OutputPeak / peak);
        var pcm = new short[output.Length];
        for (int i = 0; i < pcm.Length; i++)
            pcm[i] = (short)Math.Max(-32768, Math.Min(32767, Math.Truncate(output[i] * gain)));
        return pcm;
    }
}
