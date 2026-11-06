using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Enumeration;

class AdvRow { public string Address; public string Name = ""; public short Rssi; public bool Hid; public string Type; }

static class BtScan {
    static List<AdvRow> Watch(int seconds) {
        var rows = new Dictionary<ulong, AdvRow>();
        var w = new BluetoothLEAdvertisementWatcher();
        w.ScanningMode = BluetoothLEScanningMode.Active;
        w.Received += (s, a) => {
            lock (rows) {
                AdvRow r;
                if (!rows.TryGetValue(a.BluetoothAddress, out r)) {
                    r = new AdvRow { Address = a.BluetoothAddress.ToString("X12"), Type = a.AdvertisementType.ToString() };
                    rows[a.BluetoothAddress] = r;
                }
                r.Rssi = a.RawSignalStrengthInDBm;
                if (!string.IsNullOrEmpty(a.Advertisement.LocalName)) r.Name = a.Advertisement.LocalName;
                // 0x1812 is the HID service that remotes and keyboards advertise.
                foreach (var u in a.Advertisement.ServiceUuids)
                    if (u.ToString().StartsWith("00001812-")) r.Hid = true;
            }
        };
        w.Start();
        Thread.Sleep(seconds * 1000);
        w.Stop();
        lock (rows) return rows.Values.OrderByDescending(r => r.Hid).ThenByDescending(r => r.Rssi).ToList();
    }

    static List<string> Endpoints() {
        // Classic and LE association endpoints, the same list the Windows pairing dialog draws from.
        string aqs = "System.Devices.Aep.ProtocolId:=\"{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}\" OR System.Devices.Aep.ProtocolId:=\"{bb7bb05e-5972-42b5-94fc-76eaa7084d49}\"";
        var props = new[] { "System.Devices.Aep.IsPaired", "System.Devices.Aep.IsPresent" };
        var op = DeviceInformation.FindAllAsync(aqs, props, DeviceInformationKind.AssociationEndpoint);
        while (op.Status == Windows.Foundation.AsyncStatus.Started) Thread.Sleep(100);
        return op.GetResults().Select(d => string.Format("{0} | paired={1} | present={2}",
            d.Name, d.Properties["System.Devices.Aep.IsPaired"], d.Properties["System.Devices.Aep.IsPresent"]))
            .OrderBy(x => x).ToList();
    }

    static void Main(string[] args) {
        Console.OutputEncoding = Encoding.UTF8;
        int seconds = args.Length > 0 ? int.Parse(args[0]) : 20;
        var adv = Watch(seconds);
        Console.WriteLine("=== BLE advertisers: " + adv.Count + " ===");
        Console.WriteLine("Address       Rssi  Hid    Type                       Name");
        foreach (var r in adv)
            Console.WriteLine("{0}  {1,4}  {2,-5}  {3,-25}  {4}", r.Address, r.Rssi, r.Hid, r.Type, r.Name);
        var eps = Endpoints();
        Console.WriteLine("=== Bluetooth endpoints known to Windows: " + eps.Count + " ===");
        foreach (var e in eps) Console.WriteLine(e);
    }
}
