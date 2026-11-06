using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;
using Windows.Storage.Streams;

// 监听遥控器所有可订阅的蓝牙通道，看返回、主页、音量、静音键有没有发出数据。只读，不改设置。
class Probe : Form {
    readonly string[] prompts = { "↑（对照用，这个键已知能传到电脑）", "返回", "主页（小房子）", "音量 +", "音量 -", "静音", "↓（对照用）" };
    readonly Label prompt = new Label();
    readonly Label status = new Label();
    readonly ListBox list = new ListBox();
    readonly Button next = new Button();
    readonly StreamWriter log;
    readonly ulong address;
    readonly List<GattCharacteristic> subs = new List<GattCharacteristic>();
    BluetoothLEDevice device;
    int index;
    int eventsForPrompt;

    public Probe(string path, ulong addr) {
        address = addr;
        log = new StreamWriter(path, false, new UTF8Encoding(false)) { AutoFlush = true };
        Text = "遥控器按键探测";
        ClientSize = new Size(560, 430);
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 10f);
        status.SetBounds(16, 10, 528, 26);
        status.Text = "正在连接遥控器的蓝牙通道…";
        prompt.SetBounds(16, 40, 528, 60);
        prompt.Font = new Font("Microsoft YaHei UI", 20f, FontStyle.Bold);
        list.SetBounds(16, 106, 528, 262);
        list.TabStop = false;
        next.SetBounds(16, 380, 240, 36);
        next.Text = "按过了，下一个";
        next.TabStop = false;
        next.Click += (s, e) => Advance();
        Controls.AddRange(new Control[] { status, prompt, list, next });
        ShowPrompt();
        Shown += (s, e) => Task.Run(() => Connect());
    }

    protected override bool ProcessCmdKey(ref Message m, Keys k) { return true; }

    void ShowPrompt() {
        prompt.Text = "请按 2 下：" + prompts[index];
        log.WriteLine("=== " + prompts[index]);
        eventsForPrompt = 0;
    }

    void Advance() {
        log.WriteLine("    收到数据次数: " + eventsForPrompt);
        list.Items.Add(prompts[index] + " → " + (eventsForPrompt > 0 ? "收到 " + eventsForPrompt + " 次" : "没有"));
        if (++index >= prompts.Length) {
            log.WriteLine("=== DONE");
            Close();
            return;
        }
        ShowPrompt();
    }

    static T Wait<T>(IAsyncOperation<T> op) {
        while (op.Status == AsyncStatus.Started) System.Threading.Thread.Sleep(30);
        return op.GetResults();
    }

    void UI(Action a) {
        try { BeginInvoke(a); } catch { }
    }

    void Connect() {
        try {
            device = Wait(BluetoothLEDevice.FromBluetoothAddressAsync(address));
            if (device == null) throw new Exception("没有找到遥控器");
            log.WriteLine("连接状态: " + device.ConnectionStatus);
            var services = Wait(device.GetGattServicesAsync(BluetoothCacheMode.Uncached));
            log.WriteLine("服务读取: " + services.Status + " 数量=" + services.Services.Count);
            int count = 0;
            foreach (var svc in services.Services) {
                string sid = svc.Uuid.ToString();
                GattCharacteristicsResult chars;
                try {
                    chars = Wait(svc.GetCharacteristicsAsync(BluetoothCacheMode.Uncached));
                } catch (Exception ex) {
                    log.WriteLine("服务 " + sid + " 不可读: " + ex.GetBaseException().Message);
                    continue;
                }
                log.WriteLine("服务 " + sid + " " + chars.Status + " 特征=" + chars.Characteristics.Count);
                foreach (var c in chars.Characteristics) {
                    bool notify = (c.CharacteristicProperties & GattCharacteristicProperties.Notify) != 0;
                    bool indicate = (c.CharacteristicProperties & GattCharacteristicProperties.Indicate) != 0;
                    log.WriteLine("  特征 " + c.Uuid + " 属性=" + c.CharacteristicProperties);
                    if (!notify && !indicate) continue;
                    string cid = c.Uuid.ToString();
                    c.ValueChanged += (s, a) => {
                        var reader = DataReader.FromBuffer(a.CharacteristicValue);
                        byte[] data = new byte[reader.UnconsumedBufferLength];
                        reader.ReadBytes(data);
                        eventsForPrompt++;
                        log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + sid.Substring(4, 4) + "/" + cid.Substring(4, 4) + " " + BitConverter.ToString(data));
                        UI(() => status.Text = "收到数据：" + sid.Substring(4, 4) + "/" + cid.Substring(4, 4));
                    };
                    try {
                        var st = Wait(c.WriteClientCharacteristicConfigurationDescriptorAsync(
                            notify ? GattClientCharacteristicConfigurationDescriptorValue.Notify : GattClientCharacteristicConfigurationDescriptorValue.Indicate));
                        log.WriteLine("    订阅: " + st);
                        if (st == GattCommunicationStatus.Success) { subs.Add(c); count++; }
                    } catch (Exception ex) {
                        log.WriteLine("    订阅失败: " + ex.GetBaseException().Message);
                    }
                }
            }
            int final = count;
            UI(() => status.Text = "已监听 " + final + " 个通道。按提示操作");
        } catch (Exception ex) {
            log.WriteLine("错误: " + ex.GetBaseException().Message);
            UI(() => status.Text = "连接失败：" + ex.GetBaseException().Message);
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        foreach (var c in subs) {
            try { c.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.None); } catch { }
        }
        if (device != null) device.Dispose();
        log.Dispose();
        base.OnFormClosed(e);
    }

    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        // 用法：gattprobe.exe <日志文件> <蓝牙地址，12 位十六进制>，地址见设备实例 ID 里的 BTHLE\DEV_...
        Application.Run(new Probe(args[0], Convert.ToUInt64(args[1], 16)));
    }
}
