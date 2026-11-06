using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Speech.Recognition;
using System.Speech.Synthesis;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

// 语音输入程序，由 remote-control.ahk 启动并通过命名事件切换开始/结束。
// 配了云端 API 和 Key 时：录音，结束后上传识别，失败时退回本机识别。
// 没配时：本机离线识别，边说边出字。
// 结果用 WM_COPYDATA 发回脚本：S=开始 H=临时结果 P=云端识别中 T=最终文字 W=云端失败 D=结束 E=错误。
// 用法：dictate.exe <脚本窗口句柄> --config 配置.ini --key 密钥文件 [--wav 测试音频]
//       dictate.exe --synth 文字 输出.wav          生成测试语音
//       dictate.exe --recognize 音频.wav 结果.txt  把本机识别结果写入文件
static class Program {
    const string EventName = "Local\\RemoteControlDictationToggle";
    const int LocalAutoStopMs = 60000;
    const int CloudMaxRecordMs = 180000;
    const int MinCloudBytes = 16000; // 约 0.5 秒，更短的录音不上传
    const string ZhPrompt = "以下是普通话的句子，使用简体中文，并加上标点符号。";

    [StructLayout(LayoutKind.Sequential)]
    struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, ref COPYDATASTRUCT lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr callback);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetPrivateProfileString(string section, string key, string def, StringBuilder value, int size, string file);

    static IntPtr target;
    static string wavPath;
    static string baseUrl, model, language, apiKey;
    static bool cloud;
    static SpeechRecognitionEngine engine;
    static volatile bool listening;
    static volatile bool busy;
    static int startTick, lastSpeechTick;

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

    static SpeechRecognitionEngine CreateEngine() {
        var e = new SpeechRecognitionEngine(new CultureInfo("zh-CN"));
        e.LoadGrammar(new DictationGrammar());
        return e;
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

    static int Mci(string command) {
        return mciSendString(command, null, 0, IntPtr.Zero);
    }

    static void Start() {
        if (busy) return;
        try {
            if (cloud) {
                if (wavPath == null) {
                    Mci("close remoterec");
                    if (Mci("open new type waveaudio alias remoterec") != 0
                        || Mci("set remoterec time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2") != 0
                        || Mci("record remoterec") != 0) {
                        Mci("close remoterec");
                        Post("E", "无法打开麦克风");
                        return;
                    }
                }
            } else {
                if (wavPath != null) engine.SetInputToWaveFile(wavPath);
                else engine.SetInputToDefaultAudioDevice();
                engine.RecognizeAsync(RecognizeMode.Multiple);
            }
            listening = true;
            startTick = lastSpeechTick = Environment.TickCount;
            Post("S", "");
        } catch (Exception ex) {
            listening = false;
            Post("E", ex.Message);
        }
    }

    static void Stop() {
        listening = false;
        if (!cloud) {
            try { engine.RecognizeAsyncStop(); } catch { Post("D", ""); }
            return;
        }
        busy = true;
        string file = wavPath;
        if (wavPath == null) {
            file = Path.Combine(Path.GetTempPath(), "remote-dictate-" + Guid.NewGuid().ToString("N") + ".wav");
            Mci("stop remoterec");
            int saved = Mci("save remoterec \"" + file + "\"");
            Mci("close remoterec");
            if (saved != 0) {
                busy = false;
                Post("E", "录音保存失败");
                Post("D", "");
                return;
            }
        }
        Post("P", "");
        string captured = file;
        new Thread(() => Transcribe(captured)) { IsBackground = true }.Start();
    }

    static void Transcribe(string file) {
        try {
            if (new FileInfo(file).Length < MinCloudBytes) return;
            string text;
            try {
                text = CallApi(file);
            } catch (Exception ex) {
                Post("W", DescribeError(ex));
                text = RecognizeFile(file);
            }
            if (!string.IsNullOrEmpty(text)) Post("T", text);
        } catch (Exception ex) {
            Post("E", ex.Message);
        } finally {
            if (wavPath == null) {
                try { File.Delete(file); } catch { }
            }
            busy = false;
            Post("D", "");
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

    static string RecognizeFile(string path) {
        var parts = new StringBuilder();
        using (var e = CreateEngine()) {
            e.SetInputToWaveFile(path);
            var done = new ManualResetEvent(false);
            e.SpeechRecognized += (s, a) => parts.Append(a.Result.Text);
            e.RecognizeCompleted += (s, a) => done.Set();
            e.RecognizeAsync(RecognizeMode.Multiple);
            done.WaitOne(60000);
        }
        return parts.ToString();
    }

    static string ArgAfter(string[] args, string flag) {
        int i = Array.IndexOf(args, flag);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    static int Main(string[] args) {
        if (args.Length >= 3 && args[0] == "--synth") return Synth(args[1], args[2]);
        if (args.Length >= 3 && args[0] == "--recognize") {
            File.WriteAllText(args[2], RecognizeFile(args[1]), new UTF8Encoding(false));
            return 0;
        }
        if (args.Length < 1) return 2;
        target = new IntPtr(Convert.ToInt64(args[0]));
        wavPath = ArgAfter(args, "--wav");
        LoadConfig(ArgAfter(args, "--config"), ArgAfter(args, "--key"));

        try {
            engine = CreateEngine();
        } catch (Exception ex) {
            if (!cloud) {
                Post("E", ex.Message);
                return 1;
            }
        }
        if (engine != null) {
            engine.SpeechRecognized += (s, e) => {
                lastSpeechTick = Environment.TickCount;
                if (!string.IsNullOrEmpty(e.Result.Text)) Post("T", e.Result.Text);
            };
            engine.SpeechHypothesized += (s, e) => {
                lastSpeechTick = Environment.TickCount;
                Post("H", e.Result.Text);
            };
            engine.RecognizeCompleted += (s, e) => {
                listening = false;
                Post("D", "");
            };
        }

        using (var toggle = new EventWaitHandle(false, EventResetMode.AutoReset, EventName)) {
            while (IsWindow(target)) {
                if (toggle.WaitOne(500)) {
                    if (listening) Stop(); else Start();
                }
                // 忘记结束时自动关闭麦克风：本机模式看有没有语音，云端模式限制录音时长。
                if (listening) {
                    int now = Environment.TickCount;
                    if (cloud ? now - startTick > CloudMaxRecordMs : now - lastSpeechTick > LocalAutoStopMs) Stop();
                }
            }
        }
        if (listening && cloud && wavPath == null) Mci("close remoterec");
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
}
