// CamNetTool 原生元件（由 CamNetTool.ps1 以 Add-Type 編譯；只能用 C# 5 語法）
//   NicMonNative : GetIfEntry2、CPU 時間、工作列閃爍（沿用 NicMonitor 1.1.0）
//   GvcpClient   : GigE Vision 控制通道（UDP 3956）READREG / READMEM / WRITEREG / DISCOVERY
//   GenApiModel  : 解析相機 GenICam XML，把 feature 追到暫存器位址並計算公式
//   GenFormula   : GenICam 公式（SwissKnife / Converter）計算器
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml;

public static class NicMonNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MIB_IF_ROW2 {
        public ulong InterfaceLuid; public uint InterfaceIndex; public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string Alias;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string Description;
        public uint PhysicalAddressLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] PhysicalAddress;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] PermanentPhysicalAddress;
        public uint Mtu, Type, TunnelType, MediaType, PhysicalMediumType, AccessType, DirectionType;
        public byte InterfaceAndOperStatusFlags;
        public uint OperStatus, AdminStatus, MediaConnectState;
        public Guid NetworkGuid; public uint ConnectionType;
        public ulong TransmitLinkSpeed, ReceiveLinkSpeed;
        public ulong InOctets, InUcastPkts, InNUcastPkts, InDiscards, InErrors, InUnknownProtos, InUcastOctets, InMulticastOctets, InBroadcastOctets;
        public ulong OutOctets, OutUcastPkts, OutNUcastPkts, OutDiscards, OutErrors, OutUcastOctets, OutMulticastOctets, OutBroadcastOctets, OutQLen;
    }
    [DllImport("iphlpapi.dll")] private static extern int GetIfEntry2(ref MIB_IF_ROW2 row);
    [DllImport("iphlpapi.dll")] private static extern int ConvertInterfaceGuidToLuid(ref Guid guid, out ulong luid);
    public static int RowSize { get { return Marshal.SizeOf(typeof(MIB_IF_ROW2)); } }

    public static int QueryInterface(string guidText, out MIB_IF_ROW2 row) {
        row = new MIB_IF_ROW2();
        Guid g = new Guid(guidText);
        ulong luid;
        int rc = ConvertInterfaceGuidToLuid(ref g, out luid);
        if (rc != 0) return rc;
        row.InterfaceLuid = luid;
        return GetIfEntry2(ref row);
    }

    // AQtion 驅動的丟棄計數：真正的計數放在 64 位元的高 32 位元，低 32 位元是不相干的值。
    // packedHint = true（AQtion 網卡，或這次監控已經偵測到這種格式）而且計數值 ≥ 2^32 時，一律取高 32 位元的差。
    //   低 32 位元會自己變動（實測一次 +12,794、+27,776，甚至 +1,866,458,126），
    //   只看差值大小會把高 32 位元沒變的那幾次誤算成大量丟棄（2026-11-25 發現）。
    // 一般驅動（沒有 hint，差值小於 2^31）照原值；差值 ≥ 2^31 時也視為這種格式。
    public static long DiscardDelta(ulong prev, ulong now, out bool packed) {
        return DiscardDelta(prev, now, false, out packed);
    }

    public static long DiscardDelta(ulong prev, ulong now, bool packedHint, out bool packed) {
        packed = false;
        bool usePacked = packedHint && (now >> 32) != 0;
        if (!usePacked) {
            if (now < prev) return 0;
            ulong raw = now - prev;
            if (raw < 0x80000000UL) return (long)raw;
        }
        packed = true;
        long hi = (long)(now >> 32) - (long)(prev >> 32);
        return hi < 0 ? 0 : hi;
    }

    public static void Flash(IntPtr hwnd) {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = hwnd; f.dwFlags = 3 | 12; f.uCount = 0; f.dwTimeout = 0;
        FlashWindowEx(ref f);
    }

    [DllImport("psapi.dll")] private static extern bool EmptyWorkingSet(IntPtr hProcess);
    public static void TrimWorkingSet() { try { EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle); } catch { } }
}

// ---------------------------------------------------------------------------
//  GVCP
// ---------------------------------------------------------------------------
public class GvcpDevice {
    public string Ip, Mask, Mac, Manufacturer, Model, Version, MfgInfo, Serial, UserName, From;
    public uint IpConfigCurrent;
}

public class GvcpResult {
    public bool Ok;
    public int Status;          // 0 = 成功；-1 = 無回應；其他 = GVCP 狀態碼
    public uint Value;
    public byte[] Data;
    public string Note {
        get {
            if (Ok) return "";
            return GvcpClient.StatusText(Status);
        }
    }
}

public class GvcpClient : IDisposable {
    public const int Port = 3956;
    private Socket sock;
    private IPEndPoint cam;
    private ushort reqId;
    public int TimeoutMs = 500;
    public int Retries = 3;
    public long Sent, Received, Timeouts;
    public string LocalIp, CameraIp;

    public GvcpClient(string localIp, string cameraIp) {
        LocalIp = localIp; CameraIp = cameraIp;
        sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        sock.Bind(new IPEndPoint(IPAddress.Parse(localIp), 0));
        cam = new IPEndPoint(IPAddress.Parse(cameraIp), Port);
        reqId = (ushort)new Random().Next(0x1000, 0x7000);
    }

    public void Dispose() { if (sock != null) { try { sock.Close(); } catch { } sock = null; } }

    public static string StatusText(int s) {
        switch (s) {
            case -1: return "無回應";
            case 0x0000: return "成功";
            case 0x8001: return "NOT_IMPLEMENTED";
            case 0x8002: return "INVALID_PARAMETER";
            case 0x8003: return "INVALID_ADDRESS";
            case 0x8004: return "WRITE_PROTECT";
            case 0x8005: return "BAD_ALIGNMENT";
            case 0x8006: return "ACCESS_DENIED（有程式以獨占模式控制相機）";
            case 0x8007: return "BUSY";
            case 0x800B: return "PACKET_UNAVAILABLE";
            case 0x800C: return "DATA_OVERRUN";
            case 0x800D: return "INVALID_HEADER";
            case 0x8FFF: return "ERROR";
        }
        return "狀態碼 0x" + s.ToString("X4");
    }

    private ushort NextId() { reqId++; if (reqId == 0) reqId = 1; return reqId; }

    static void Put16(byte[] b, int o, int v) { b[o] = (byte)(v >> 8); b[o + 1] = (byte)v; }
    static void Put32(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
    public static int Get16(byte[] b, int o) { return (b[o] << 8) | b[o + 1]; }
    public static uint Get32(byte[] b, int o) { return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3]; }

    static byte[] Build(int flags, int cmd, byte[] payload, ushort id) {
        int len = payload == null ? 0 : payload.Length;
        byte[] b = new byte[8 + len];
        b[0] = 0x42; b[1] = (byte)flags;
        Put16(b, 2, cmd); Put16(b, 4, len); Put16(b, 6, id);
        if (len > 0) Buffer.BlockCopy(payload, 0, b, 8, len);
        return b;
    }

    private void Drain() {
        byte[] buf = new byte[1600];
        EndPoint ep = new IPEndPoint(IPAddress.Any, 0);
        while (sock.Available > 0) { try { sock.ReceiveFrom(buf, ref ep); } catch { break; } }
    }

    // 送出指令並等待對應的 ACK（處理 PENDING_ACK）；回傳完整回應封包，無回應回傳 null
    public byte[] Transact(int cmd, byte[] payload, int ackCmd, out int status) {
        status = -1;
        if (sock == null) throw new ObjectDisposedException("GvcpClient");
        Drain();
        ushort id = NextId();
        byte[] pkt = Build(0x01, cmd, payload, id);
        byte[] buf = new byte[1600];
        for (int attempt = 0; attempt < Retries; attempt++) {
            sock.SendTo(pkt, cam); Sent++;
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(TimeoutMs);
            while (true) {
                int remain = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (remain <= 0) break;
                if (!sock.Poll(remain * 1000, SelectMode.SelectRead)) break;
                EndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                int n;
                try { n = sock.ReceiveFrom(buf, ref ep); } catch (SocketException) { continue; }
                if (n < 8 || Get16(buf, 6) != id) continue;
                int ack = Get16(buf, 2);
                if (ack == 0x0089) {             // PENDING_ACK：相機要求延長等待
                    int extra = n >= 12 ? Get16(buf, 10) : 500;
                    deadline = DateTime.UtcNow.AddMilliseconds(extra + 200);
                    continue;
                }
                if (ack != ackCmd) continue;
                Received++;
                status = Get16(buf, 0);
                byte[] r = new byte[n];
                Buffer.BlockCopy(buf, 0, r, 0, n);
                return r;
            }
            Timeouts++;
        }
        return null;
    }

    public GvcpResult ReadReg(uint addr) {
        byte[] p = new byte[4]; Put32(p, 0, addr);
        int st;
        byte[] r = Transact(0x0080, p, 0x0081, out st);
        GvcpResult res = new GvcpResult();
        res.Status = st;
        if (r != null && st == 0 && r.Length >= 12) { res.Ok = true; res.Value = Get32(r, 8); }
        return res;
    }

    // 一次讀多個暫存器（READREG 可帶多個位址）；相機不支援時自動改為逐一讀取
    public bool MultiReadSupported = true;
    public GvcpResult[] ReadRegs(uint[] addrs) {
        GvcpResult[] res = new GvcpResult[addrs.Length];
        int i0 = 0;
        while (i0 < addrs.Length) {
            int n = Math.Min(64, addrs.Length - i0);
            bool done = false;
            if (MultiReadSupported && n > 1) {
                byte[] p = new byte[4 * n];
                for (int k = 0; k < n; k++) Put32(p, 4 * k, addrs[i0 + k]);
                int st;
                byte[] r = Transact(0x0080, p, 0x0081, out st);
                if (r == null) {
                    for (int k = 0; k < n; k++) { res[i0 + k] = new GvcpResult(); res[i0 + k].Status = -1; }
                    done = true;
                } else if (st == 0 && r.Length >= 8 + 4 * n) {
                    for (int k = 0; k < n; k++) { GvcpResult g = new GvcpResult(); g.Ok = true; g.Status = 0; g.Value = Get32(r, 8 + 4 * k); res[i0 + k] = g; }
                    done = true;
                }
                // 狀態錯誤（例如其中一個位址無效）：改逐一讀，找出是哪一個
            }
            if (!done) {
                for (int k = 0; k < n; k++) {
                    res[i0 + k] = ReadReg(addrs[i0 + k]);
                    if (res[i0 + k].Status == -1) {       // 無回應就不要再一個個等
                        for (int j = k + 1; j < n; j++) { res[i0 + j] = new GvcpResult(); res[i0 + j].Status = -1; }
                        break;
                    }
                }
            }
            i0 += n;
        }
        return res;
    }

    public GvcpResult ReadMem(uint addr, int count) {
        GvcpResult res = new GvcpResult();
        if (count <= 0 || count > 536 || (count % 4) != 0) throw new ArgumentException("READMEM count 必須是 4 的倍數且 <= 536");
        byte[] p = new byte[8]; Put32(p, 0, addr); Put16(p, 6, count);
        int st;
        byte[] r = Transact(0x0084, p, 0x0085, out st);
        res.Status = st;
        if (r != null && st == 0 && r.Length >= 12) {
            res.Ok = true;
            res.Data = new byte[r.Length - 12];
            Buffer.BlockCopy(r, 12, res.Data, 0, res.Data.Length);
        }
        return res;
    }

    public byte[] ReadBlock(uint addr, int length) {
        byte[] all = new byte[length];
        int off = 0;
        while (off < length) {
            int n = Math.Min(512, length - off);
            int n4 = (n + 3) / 4 * 4;
            GvcpResult r = ReadMem((uint)(addr + off), n4);
            if (!r.Ok) throw new Exception("READMEM 0x" + (addr + off).ToString("X8") + " 失敗：" + r.Note);
            Buffer.BlockCopy(r.Data, 0, all, off, Math.Min(n, r.Data.Length));
            off += n;
        }
        return all;
    }

    public string ReadString(uint addr, int length) {
        GvcpResult r = ReadMem(addr, (length + 3) / 4 * 4);
        if (!r.Ok) return null;
        return AsciiZ(r.Data, 0, Math.Min(length, r.Data.Length));
    }

    public GvcpResult WriteReg(uint addr, uint value) {
        byte[] p = new byte[8]; Put32(p, 0, addr); Put32(p, 4, value);
        int st;
        byte[] r = Transact(0x0082, p, 0x0083, out st);
        GvcpResult res = new GvcpResult();
        res.Status = st;
        res.Ok = (r != null && st == 0);
        return res;
    }

    public static string AsciiZ(byte[] d, int o, int n) {
        if (d == null || o >= d.Length) return "";
        n = Math.Min(n, d.Length - o);
        string s = Encoding.ASCII.GetString(d, o, n);
        int z = s.IndexOf('\0');
        if (z >= 0) s = s.Substring(0, z);
        return s.Trim();
    }

    static string Ip(byte[] b, int o) { return b[o] + "." + b[o + 1] + "." + b[o + 2] + "." + b[o + 3]; }

    public static GvcpDevice ParseDiscovery(byte[] r, string from) {
        int p = 8;
        if (r.Length < p + 248) return null;
        GvcpDevice d = new GvcpDevice();
        d.From = from;
        d.Mac = string.Format("{0:X2}-{1:X2}-{2:X2}-{3:X2}-{4:X2}-{5:X2}", r[p + 10], r[p + 11], r[p + 12], r[p + 13], r[p + 14], r[p + 15]);
        d.IpConfigCurrent = Get32(r, p + 20);
        d.Ip = Ip(r, p + 36);
        d.Mask = Ip(r, p + 52);
        d.Manufacturer = AsciiZ(r, p + 72, 32);
        d.Model = AsciiZ(r, p + 104, 32);
        d.Version = AsciiZ(r, p + 136, 32);
        d.MfgInfo = AsciiZ(r, p + 168, 48);
        d.Serial = AsciiZ(r, p + 216, 16);
        d.UserName = AsciiZ(r, p + 232, 16);
        return d;
    }

    // DISCOVERY：從指定的本機 IP 送出廣播（以及可選的 unicast），收集回應
    public static List<GvcpDevice> Discover(string localIp, string[] targets, int timeoutMs) {
        List<GvcpDevice> list = new List<GvcpDevice>();
        Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try {
            s.EnableBroadcast = true;
            s.Bind(new IPEndPoint(IPAddress.Parse(localIp), 0));
            ushort id = (ushort)new Random().Next(0x7000, 0x7FFF);
            byte[] pkt = Build(0x11, 0x0002, null, id);     // 0x10 = 允許相機以廣播回應（IP 不在同網段時）
            foreach (string t in targets) {
                try { s.SendTo(pkt, new IPEndPoint(IPAddress.Parse(t), Port)); } catch { }
            }
            byte[] buf = new byte[1600];
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (true) {
                int remain = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (remain <= 0) break;
                if (!s.Poll(remain * 1000, SelectMode.SelectRead)) break;
                EndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                int n;
                try { n = s.ReceiveFrom(buf, ref ep); } catch (SocketException) { continue; }
                if (n < 8 || Get16(buf, 2) != 0x0003) continue;
                byte[] r = new byte[n]; Buffer.BlockCopy(buf, 0, r, 0, n);
                GvcpDevice d = ParseDiscovery(r, ((IPEndPoint)ep).Address.ToString());
                if (d == null) continue;
                bool dup = false;
                foreach (GvcpDevice x in list) if (x.Mac == d.Mac) dup = true;
                if (!dup) list.Add(d);
            }
        } finally { s.Close(); }
        return list;
    }
}

// ---------------------------------------------------------------------------
//  pktmon pcapng 分析（對應 reference/fast_pcapng.py、resend_check.py）
//  每張影像的封包數、送完時間、突發速率、缺漏、PACKETRESEND，以及被要求重送的封包原本有沒有出現在擷取中
// ---------------------------------------------------------------------------
public class PcapBlockStat {
    public ulong BlockId; public int Packets; public uint MaxPid; public int Missing; public double FirstTs, LastTs; public long Bytes;
    public double DurationMs { get { return (LastTs - FirstTs) * 1000.0; } }
}
public class PcapResendReq { public double Ts; public ulong BlockId; public uint First, Last; public int Requested, SeenBefore, SeenAfter; }
public class PcapAnalysis {
    public long RawPackets, UniquePackets, StreamPackets, GvcpCmds, GvcpAcks;
    public double DurationSec;
    public List<PcapBlockStat> Blocks = new List<PcapBlockStat>();
    public List<PcapResendReq> Resends = new List<PcapResendReq>();
    public int CompleteBlocks; public double MedianBlockMs, MedianBurstMBps; public int MedianPackets;
    public int ResendPacketsRequested, ResendSeenBefore, ResendSeenAfter;
    public string Error;
}

public static class PcapngAnalyzer {
    static uint U32(byte[] b, int o, bool le) { return le ? BitConverter.ToUInt32(b, o) : (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]); }
    static int Be16(byte[] b, int o) { return (b[o] << 8) | b[o + 1]; }
    static uint Be32(byte[] b, int o) { return (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]); }
    static ulong Be64(byte[] b, int o) { return ((ulong)Be32(b, o) << 32) | Be32(b, o + 4); }

    public static PcapAnalysis Analyze(string path, string cameraIp) {
        PcapAnalysis a = new PcapAnalysis();
        byte[] cam = IPAddress.Parse(cameraIp).GetAddressBytes();
        // (block, pid) → 每次出現的時間（以 IP id 去重：pktmon 在多個擷取點會記錄同一個封包）
        Dictionary<ulong, Dictionary<uint, List<double>>> occ = new Dictionary<ulong, Dictionary<uint, List<double>>>();
        Dictionary<ulong, PcapBlockStat> blocks = new Dictionary<ulong, PcapBlockStat>();
        HashSet<string> seen = new HashSet<string>();
        List<int> linkTypes = new List<int>();
        double tmin = double.MaxValue, tmax = 0;
        try {
            using (System.IO.FileStream fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.Read, 1 << 20)) {
                byte[] head = new byte[12];
                byte[] buf = new byte[65536];
                bool le = true;
                while (true) {
                    if (fs.Read(head, 0, 8) < 8) break;
                    uint btype = BitConverter.ToUInt32(head, 0);
                    if (btype == 0x0A0D0D0A) {
                        fs.Read(head, 8, 4);
                        le = BitConverter.ToUInt32(head, 8) == 0x1A2B3C4D;
                        uint shbLen = U32(head, 4, le);
                        fs.Seek(shbLen - 12, System.IO.SeekOrigin.Current);
                        continue;
                    }
                    if (!le) btype = U32(head, 0, false);
                    uint blen = U32(head, 4, le);
                    if (blen < 12 || blen > 16 * 1024 * 1024) { a.Error = "pcapng 區塊長度異常"; break; }
                    int body = (int)blen - 8;
                    if (buf.Length < body) buf = new byte[body];
                    if (fs.Read(buf, 0, body) < body) break;
                    if (btype == 1) { linkTypes.Add(le ? BitConverter.ToUInt16(buf, 0) : Be16(buf, 0)); continue; }
                    if (btype != 6) continue;
                    a.RawPackets++;
                    uint iid = U32(buf, 0, le), th = U32(buf, 4, le), tl = U32(buf, 8, le), caplen = U32(buf, 12, le);
                    int lt = iid < linkTypes.Count ? linkTypes[(int)iid] : 1;
                    int p0 = 20;           // 封包資料在 EPB 本體內的位置
                    int end = p0 + (int)caplen;
                    int p;
                    if (lt == 1) {
                        if (caplen < 14) continue;
                        int et = Be16(buf, p0 + 12); p = p0 + 14;
                        if (et == 0x8100) { et = Be16(buf, p0 + 16); p = p0 + 18; }
                        if (et != 0x0800) continue;
                    } else if (lt == 101 || lt == 228) { p = p0; } else continue;
                    if (end < p + 28) continue;
                    int ihl = (buf[p] & 0x0F) * 4;
                    if (buf[p + 9] != 17) continue;
                    bool fromCam = buf[p + 12] == cam[0] && buf[p + 13] == cam[1] && buf[p + 14] == cam[2] && buf[p + 15] == cam[3];
                    bool toCam = buf[p + 16] == cam[0] && buf[p + 17] == cam[1] && buf[p + 18] == cam[2] && buf[p + 19] == cam[3];
                    if (!fromCam && !toCam) continue;
                    int ipid = Be16(buf, p + 4);
                    int u = p + ihl;
                    if (end < u + 8) continue;
                    int sport = Be16(buf, u), dport = Be16(buf, u + 2), udpLen = Be16(buf, u + 4);
                    int pl = u + 8;
                    int plLen = end - pl;
                    StringBuilder key = new StringBuilder();
                    key.Append(fromCam ? 'c' : 'h').Append(sport).Append(':').Append(dport).Append(':').Append(ipid).Append(':');
                    for (int i = 0; i < 12 && i < plLen; i++) key.Append(buf[pl + i].ToString("x2"));
                    if (!seen.Add(key.ToString())) continue;
                    a.UniquePackets++;
                    double ts = (((ulong)th << 32) | tl) / 1e6;
                    if (ts < tmin) tmin = ts; if (ts > tmax) tmax = ts;
                    if (toCam && dport == GvcpClient.Port && plLen >= 8 && buf[pl] == 0x42) {
                        a.GvcpCmds++;
                        int cmd = Be16(buf, pl + 2);
                        if (cmd == 0x0040 && plLen >= 8 + 12) {
                            PcapResendReq r = new PcapResendReq(); r.Ts = ts;
                            bool ext = (buf[pl + 1] & 0x10) != 0;
                            r.First = Be32(buf, pl + 12) & (ext ? 0xFFFFFFFFu : 0x00FFFFFFu);
                            r.Last = Be32(buf, pl + 16) & (ext ? 0xFFFFFFFFu : 0x00FFFFFFu);
                            r.BlockId = ext && plLen >= 8 + 20 ? Be64(buf, pl + 20) : (ulong)Be16(buf, pl + 10);
                            a.Resends.Add(r);
                        }
                    } else if (fromCam && sport == GvcpClient.Port) {
                        a.GvcpAcks++;
                    } else if (fromCam && plLen >= 8) {
                        a.StreamPackets++;
                        bool ei = (buf[pl + 4] & 0x80) != 0;
                        ulong bid; uint pid;
                        if (ei) { if (plLen < 20) continue; bid = Be64(buf, pl + 8); pid = Be32(buf, pl + 16); }
                        else { bid = (ulong)Be16(buf, pl + 2); pid = ((uint)buf[pl + 5] << 16) | ((uint)buf[pl + 6] << 8) | buf[pl + 7]; }
                        PcapBlockStat bs;
                        if (!blocks.TryGetValue(bid, out bs)) { bs = new PcapBlockStat(); bs.BlockId = bid; bs.FirstTs = ts; blocks[bid] = bs; }
                        bs.Packets++; bs.LastTs = Math.Max(bs.LastTs, ts); bs.FirstTs = Math.Min(bs.FirstTs, ts);
                        bs.Bytes += Math.Max(0, udpLen - 8);
                        if (pid > bs.MaxPid) bs.MaxPid = pid;
                        Dictionary<uint, List<double>> m;
                        if (!occ.TryGetValue(bid, out m)) { m = new Dictionary<uint, List<double>>(); occ[bid] = m; }
                        List<double> l;
                        if (!m.TryGetValue(pid, out l)) { l = new List<double>(2); m[pid] = l; }
                        l.Add(ts);
                    }
                }
            }
        } catch (Exception ex) { a.Error = ex.Message; }
        if (a.UniquePackets > 0) a.DurationSec = tmax - tmin;
        // 每張影像：缺漏（packet id 0 是 leader；1..maxpid 之間沒出現的）
        List<ulong> ids = new List<ulong>(blocks.Keys); ids.Sort();
        List<double> durs = new List<double>(); List<double> rates = new List<double>(); List<int> pkts = new List<int>();
        for (int i = 0; i < ids.Count; i++) {
            PcapBlockStat b = blocks[ids[i]];
            int distinct = occ[b.BlockId].Count;
            b.Missing = (int)b.MaxPid + 1 - distinct;
            if (b.Missing < 0) b.Missing = 0;
            a.Blocks.Add(b);
            // 擷取開頭、結尾的那兩張可能不完整，不列入中位數
            if (i > 0 && i < ids.Count - 1 && b.DurationMs > 0) {
                a.CompleteBlocks++;
                durs.Add(b.DurationMs); rates.Add(b.Bytes / (b.DurationMs / 1000.0) / 1e6); pkts.Add(b.Packets);
            }
        }
        if (durs.Count > 0) {
            durs.Sort(); rates.Sort(); pkts.Sort();
            a.MedianBlockMs = durs[durs.Count / 2]; a.MedianBurstMBps = rates[rates.Count / 2]; a.MedianPackets = pkts[pkts.Count / 2];
        }
        // 被要求重送的封包：原本（重送要求之前）有沒有出現在擷取中
        foreach (PcapResendReq r in a.Resends) {
            Dictionary<uint, List<double>> m;
            occ.TryGetValue(r.BlockId, out m);
            for (uint pid = r.First; pid <= r.Last && pid - r.First < 10000; pid++) {
                r.Requested++;
                List<double> l = null;
                if (m != null) m.TryGetValue(pid, out l);
                if (l == null) continue;
                bool before = false, after = false;
                foreach (double t in l) { if (t < r.Ts) before = true; else after = true; }
                if (before) r.SeenBefore++;
                if (after) r.SeenAfter++;
            }
            a.ResendPacketsRequested += r.Requested; a.ResendSeenBefore += r.SeenBefore; a.ResendSeenAfter += r.SeenAfter;
        }
        return a;
    }
}

// ---------------------------------------------------------------------------
//  GenICam 公式
// ---------------------------------------------------------------------------
public class GenFormula {
    private string src; private int pos;
    private Dictionary<string, double> vars;

    public static double Eval(string formula, Dictionary<string, double> variables) {
        GenFormula f = new GenFormula();
        f.src = formula; f.pos = 0; f.vars = variables;
        double v = f.Ternary();
        f.Skip();
        if (f.pos < f.src.Length) throw new FormatException("公式多出內容：" + f.src.Substring(f.pos));
        return v;
    }

    // 只取出公式用到的變數名稱（用於顯示與驗證）
    public static string Normalize(string formula) {
        if (formula == null) return "";
        StringBuilder sb = new StringBuilder();
        foreach (char c in formula) if (!char.IsWhiteSpace(c)) sb.Append(c);
        return sb.ToString();
    }

    void Skip() { while (pos < src.Length && char.IsWhiteSpace(src[pos])) pos++; }
    bool Try(string op) {
        Skip();
        if (string.CompareOrdinal(src, pos, op, 0, op.Length) == 0) {
            // 避免把 "<=" 誤判成 "<"、"**" 誤判成 "*" 等
            if (op.Length == 1 && pos + 1 < src.Length) {
                char n = src[pos + 1];
                if ((op == "<" || op == ">") && (n == '=' || n == op[0] || (op == "<" && n == '>'))) return false;
                if (op == "*" && n == '*') return false;
                if (op == "&" && n == '&') return false;
                if (op == "|" && n == '|') return false;
                if (op == "=" && n == '=') { pos += 2; return true; }
            }
            pos += op.Length; return true;
        }
        return false;
    }
    static bool B(double v) { return v != 0; }
    static long L(double v) { return (long)Math.Truncate(v); }

    double Ternary() {
        double c = Or();
        if (Try("?")) { double a = Ternary(); if (!Try(":")) throw new FormatException("缺少 ':'"); double b = Ternary(); return B(c) ? a : b; }
        return c;
    }
    double Or() { double v = And(); while (Try("||")) { double r = And(); v = (B(v) || B(r)) ? 1 : 0; } return v; }
    double And() { double v = BitOr(); while (Try("&&")) { double r = BitOr(); v = (B(v) && B(r)) ? 1 : 0; } return v; }
    double BitOr() { double v = BitXor(); while (Try("|")) v = L(v) | L(BitXor()); return v; }
    double BitXor() { double v = BitAnd(); while (Try("^")) v = L(v) ^ L(BitAnd()); return v; }
    double BitAnd() { double v = Eq(); while (Try("&")) v = L(v) & L(Eq()); return v; }
    double Eq() {
        double v = Rel();
        while (true) {
            if (Try("<>")) { v = v != Rel() ? 1 : 0; continue; }
            if (Try("!=")) { v = v != Rel() ? 1 : 0; continue; }
            if (Try("=")) { v = v == Rel() ? 1 : 0; continue; }
            return v;
        }
    }
    double Rel() {
        double v = Shift();
        while (true) {
            if (Try("<=")) { v = v <= Shift() ? 1 : 0; continue; }
            if (Try(">=")) { v = v >= Shift() ? 1 : 0; continue; }
            if (Try("<")) { v = v < Shift() ? 1 : 0; continue; }
            if (Try(">")) { v = v > Shift() ? 1 : 0; continue; }
            return v;
        }
    }
    double Shift() {
        double v = Add();
        while (true) {
            if (Try("<<")) { v = L(v) << (int)L(Add()); continue; }
            if (Try(">>")) { v = L(v) >> (int)L(Add()); continue; }
            return v;
        }
    }
    double Add() {
        double v = Mul();
        while (true) {
            if (Try("+")) { v += Mul(); continue; }
            if (Try("-")) { v -= Mul(); continue; }
            return v;
        }
    }
    double Mul() {
        double v = Pow();
        while (true) {
            if (Try("*")) { v *= Pow(); continue; }
            if (Try("/")) { v /= Pow(); continue; }
            if (Try("%")) { v = L(v) % L(Pow()); continue; }
            return v;
        }
    }
    double Pow() { double v = Unary(); if (Try("**")) return Math.Pow(v, Pow()); return v; }
    double Unary() {
        if (Try("-")) return -Unary();
        if (Try("+")) return Unary();
        if (Try("~")) return ~L(Unary());
        if (Try("!")) return B(Unary()) ? 0 : 1;
        return Primary();
    }
    double Primary() {
        Skip();
        if (Try("(")) { double v = Ternary(); if (!Try(")")) throw new FormatException("缺少 ')'"); return v; }
        if (pos >= src.Length) throw new FormatException("公式不完整");
        char c = src[pos];
        if (char.IsDigit(c) || c == '.') {
            int s = pos;
            if (c == '0' && pos + 1 < src.Length && (src[pos + 1] == 'x' || src[pos + 1] == 'X')) {
                pos += 2; s = pos;
                while (pos < src.Length && Uri.IsHexDigit(src[pos])) pos++;
                return (double)Convert.ToUInt64(src.Substring(s, pos - s), 16);
            }
            while (pos < src.Length && (char.IsDigit(src[pos]) || src[pos] == '.' || src[pos] == 'e' || src[pos] == 'E' ||
                   ((src[pos] == '-' || src[pos] == '+') && (src[pos - 1] == 'e' || src[pos - 1] == 'E')))) pos++;
            return double.Parse(src.Substring(s, pos - s), CultureInfo.InvariantCulture);
        }
        if (char.IsLetter(c) || c == '_') {
            int s = pos;
            while (pos < src.Length && (char.IsLetterOrDigit(src[pos]) || src[pos] == '_' || src[pos] == '.')) pos++;
            string name = src.Substring(s, pos - s);
            Skip();
            if (pos < src.Length && src[pos] == '(') {
                pos++;
                double a = Ternary();
                if (!Try(")")) throw new FormatException("缺少 ')'");
                return Func(name, a);
            }
            double v;
            if (vars != null && vars.TryGetValue(name, out v)) return v;
            string u = name.ToUpperInvariant();
            if (u == "PI") return Math.PI;
            if (u == "E") return Math.E;
            throw new FormatException("公式中的變數沒有定義：" + name);
        }
        throw new FormatException("無法解析的字元：" + c);
    }
    static double Func(string name, double a) {
        switch (name.ToUpperInvariant()) {
            case "SGN": return Math.Sign(a);
            case "NEG": return -a;
            case "ABS": return Math.Abs(a);
            case "SQRT": return Math.Sqrt(a);
            case "EXP": return Math.Exp(a);
            case "LN": return Math.Log(a);
            case "LG": return Math.Log10(a);
            case "SIN": return Math.Sin(a);
            case "COS": return Math.Cos(a);
            case "TAN": return Math.Tan(a);
            case "ASIN": return Math.Asin(a);
            case "ACOS": return Math.Acos(a);
            case "ATAN": return Math.Atan(a);
            case "TRUNC": return Math.Truncate(a);
            case "FLOOR": return Math.Floor(a);
            case "CEIL": return Math.Ceiling(a);
            case "ROUND": return Math.Round(a, MidpointRounding.AwayFromZero);
        }
        throw new FormatException("不支援的函式：" + name);
    }
}

// ---------------------------------------------------------------------------
//  GenICam XML 模型
// ---------------------------------------------------------------------------
public class GenRegister {
    public string Node;
    public ulong Address;
    public int Length = 4;
    public bool BigEndian = true;
    public bool Signed;
    public int Lsb = -1, Msb = -1;      // MaskedIntReg（-1 = 整個暫存器）
    public bool IsFloat;
    public string AccessMode = "RO";
}

public class GenFeatureInfo {
    public string Name, Type, Error;
    public bool Found;
    public List<GenRegister> Registers = new List<GenRegister>();
    public List<string> Formulas = new List<string>();     // 一路上遇到的公式（Formula / FormulaFrom）
    public Dictionary<long, string> EnumNames = new Dictionary<long, string>();
    public Dictionary<string, long> EnumValues = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    public string Unit = "";
    public string AccessMode = "";
    public ulong? DirectAddress;        // 直接對應到單一暫存器（可寫入）時的位址
    public GenRegister DirectRegister;
    public long CommandValue = 1;
    public string FormulaText { get { return string.Join(" ; ", Formulas.ToArray()); } }
}

public class GenEvalResult {
    public bool Ok;
    public double Value;
    public long Raw;
    public string Text, Error;
}

public class GenApiModel {
    private Dictionary<string, XmlElement> nodes = new Dictionary<string, XmlElement>(StringComparer.Ordinal);
    public string ModelName, Vendor, SchemaVersion;
    public int NodeCount { get { return nodes.Count; } }

    public static GenApiModel Load(string xmlText) {
        GenApiModel m = new GenApiModel();
        XmlDocument doc = new XmlDocument();
        doc.XmlResolver = null;
        doc.LoadXml(xmlText);
        XmlElement root = doc.DocumentElement;
        m.ModelName = root.GetAttribute("ModelName");
        m.Vendor = root.GetAttribute("VendorName");
        m.SchemaVersion = root.GetAttribute("SchemaMajorVersion") + "." + root.GetAttribute("SchemaMinorVersion");
        foreach (XmlNode n in root.GetElementsByTagName("*")) {
            XmlElement e = n as XmlElement;
            if (e == null) continue;
            string name = e.GetAttribute("Name");
            if (string.IsNullOrEmpty(name)) continue;
            // EnumEntry 也會用相同的 Name（例如 TriggerMode），建對照表時排除
            if (e.LocalName == "EnumEntry") continue;
            if (!m.nodes.ContainsKey(name)) m.nodes[name] = e;
        }
        return m;
    }

    public bool Has(string name) { return nodes.ContainsKey(name); }

    public string NodeType(string name) { XmlElement e; return nodes.TryGetValue(name, out e) ? e.LocalName : null; }

    static string Child(XmlElement e, string tag) {
        foreach (XmlNode c in e.ChildNodes) if (c.LocalName == tag) return c.InnerText.Trim();
        return null;
    }
    static List<XmlElement> Children(XmlElement e, string tag) {
        List<XmlElement> l = new List<XmlElement>();
        foreach (XmlNode c in e.ChildNodes) { XmlElement x = c as XmlElement; if (x != null && x.LocalName == tag) l.Add(x); }
        return l;
    }
    static long ParseInt(string s) {
        s = s.Trim();
        if (s.StartsWith("0x") || s.StartsWith("0X")) return (long)Convert.ToUInt64(s.Substring(2), 16);
        return long.Parse(s, CultureInfo.InvariantCulture);
    }
    static double ParseNum(string s) {
        s = s.Trim();
        if (s.StartsWith("0x") || s.StartsWith("0X")) return (double)Convert.ToUInt64(s.Substring(2), 16);
        return double.Parse(s, CultureInfo.InvariantCulture);
    }

    // 解析 feature：找出它用到的暫存器與公式
    public GenFeatureInfo Resolve(string name) {
        GenFeatureInfo info = new GenFeatureInfo();
        info.Name = name;
        XmlElement e;
        if (!nodes.TryGetValue(name, out e)) { info.Error = "XML 中找不到 " + name; return info; }
        info.Found = true;
        info.Type = e.LocalName;
        info.Unit = Child(e, "Unit") ?? "";
        if (e.LocalName == "Enumeration") {
            foreach (XmlElement ee in Children(e, "EnumEntry")) {
                string v = Child(ee, "Value");
                if (v == null) continue;
                long iv = ParseInt(v);
                string en = ee.GetAttribute("Name");
                if (!info.EnumNames.ContainsKey(iv)) info.EnumNames[iv] = en;
                info.EnumValues[en] = iv;
            }
        }
        if (e.LocalName == "Command") {
            string cv = Child(e, "CommandValue");
            if (cv != null) info.CommandValue = ParseInt(cv);
        }
        try {
            Collect(e, info, new HashSet<string>(), 0);
        } catch (Exception ex) { info.Error = ex.Message; }
        // 直接對應：feature → (pValue) → 單一 IntReg/MaskedIntReg，中間沒有公式
        XmlElement target = e;
        for (int i = 0; i < 4; i++) {
            if (target.LocalName == "IntReg" || target.LocalName == "MaskedIntReg" || target.LocalName == "StructEntry") break;
            string pv = Child(target, "pValue");
            if (pv == null || !nodes.ContainsKey(pv)) { target = null; break; }
            XmlElement nx = nodes[pv];
            if (nx.LocalName == "IntSwissKnife" || nx.LocalName == "SwissKnife" || nx.LocalName == "Converter" || nx.LocalName == "IntConverter") { target = null; break; }
            target = nx;
        }
        if (target != null && (target.LocalName == "IntReg" || target.LocalName == "MaskedIntReg" || target.LocalName == "StructEntry")) {
            try {
                GenRegister r = MakeRegister(target);
                if (r != null) { info.DirectAddress = r.Address; info.DirectRegister = r; info.AccessMode = r.AccessMode; }
            } catch (Exception ex) { if (info.Error == null) info.Error = ex.Message; }
        }
        return info;
    }

    GenRegister MakeRegister(XmlElement e) {
        if (e.LocalName == "StructEntry") {
            // StructReg 裡的一個欄位：位址、長度、位元組順序在上層 StructReg，位元範圍在自己身上
            XmlElement parent = e.ParentNode as XmlElement;
            if (parent == null) return null;
            GenRegister pr = MakeRegisterCore(parent, parent.GetAttribute("Name"));
            if (pr == null) return null;
            pr.Node = e.GetAttribute("Name");
            string lsb = Child(e, "LSB"), msb = Child(e, "MSB"), bit = Child(e, "Bit");
            if (bit != null) { pr.Lsb = pr.Msb = (int)ParseInt(bit); }
            else if (lsb != null || msb != null) { pr.Lsb = lsb != null ? (int)ParseInt(lsb) : 0; pr.Msb = msb != null ? (int)ParseInt(msb) : 0; }
            string sg = Child(e, "Sign"); if (sg != null) pr.Signed = sg == "Signed";
            string am = Child(e, "AccessMode"); if (am != null) pr.AccessMode = am;
            return pr;
        }
        return MakeRegisterCore(e, e.GetAttribute("Name"));
    }

    GenRegister MakeRegisterCore(XmlElement e, string nodeName) {
        GenRegister r = new GenRegister();
        r.Node = nodeName;
        ulong addr = 0;
        bool any = false;
        Dictionary<ulong, uint> none = new Dictionary<ulong, uint>();
        foreach (XmlNode c in e.ChildNodes) {
            XmlElement ce = c as XmlElement;
            if (ce == null) continue;
            if (ce.LocalName == "Address") { addr += (ulong)ParseInt(ce.InnerText); any = true; }
            else if (ce.LocalName == "IntSwissKnife" || ce.LocalName == "pAddress") {
                // 位址偏移量由 selector 決定（例如 V1 * 4）。selector 是常數時可以直接算出；要讀相機才知道的就不支援
                try {
                    double off;
                    if (ce.LocalName == "IntSwissKnife") off = EvalNode(ce, none, 0);
                    else {
                        XmlElement te;
                        if (!nodes.TryGetValue(ce.InnerText.Trim(), out te)) throw new Exception("找不到 " + ce.InnerText);
                        off = EvalNode(te, none, 0);
                    }
                    addr += (ulong)(long)off; any = true;
                } catch (Exception ex) {
                    throw new NotSupportedException(r.Node + " 的位址需要讀取相機才能計算（" + ce.LocalName + "）：" + ex.Message);
                }
            }
            else if (ce.LocalName == "pIndex") {
                throw new NotSupportedException(r.Node + " 的位址依索引變動（pIndex），目前不支援");
            }
        }
        if (!any) return null;
        r.Address = addr;
        string len = Child(e, "Length"); if (len != null) r.Length = (int)ParseInt(len);
        string en = Child(e, "Endianess"); if (en != null) r.BigEndian = en != "LittleEndian";
        string sg = Child(e, "Sign"); r.Signed = sg == "Signed";
        string am = Child(e, "AccessMode"); if (am != null) r.AccessMode = am;
        string lsb = Child(e, "LSB"), msb = Child(e, "MSB"), bit = Child(e, "Bit");
        if (bit != null) { r.Lsb = r.Msb = (int)ParseInt(bit); }
        else if (lsb != null || msb != null) { r.Lsb = lsb != null ? (int)ParseInt(lsb) : 0; r.Msb = msb != null ? (int)ParseInt(msb) : 0; }
        r.IsFloat = e.LocalName == "FloatReg";
        return r;
    }

    void Collect(XmlElement e, GenFeatureInfo info, HashSet<string> seen, int depth) {
        string name = e.GetAttribute("Name");
        if (depth > 12 || seen.Contains(name)) return;
        seen.Add(name);
        string t = e.LocalName;
        if (t == "IntReg" || t == "MaskedIntReg" || t == "FloatReg" || t == "StructEntry") {
            GenRegister r = MakeRegister(e);
            if (r != null) { bool dup = false; foreach (GenRegister x in info.Registers) if (x.Node == r.Node) dup = true; if (!dup) info.Registers.Add(r); }
            return;
        }
        if (t == "SwissKnife" || t == "IntSwissKnife") { string f = Child(e, "Formula"); if (f != null) info.Formulas.Add(name + ": " + f); }
        if (t == "Converter" || t == "IntConverter") { string f = Child(e, "FormulaFrom"); if (f != null) info.Formulas.Add(name + ": " + f); }
        foreach (XmlNode c in e.ChildNodes) {
            XmlElement x = c as XmlElement;
            if (x == null) continue;
            string ct = x.LocalName;
            if (ct == "pValue" || ct == "pVariable") {
                string target = x.InnerText.Trim();
                XmlElement te;
                if (nodes.TryGetValue(target, out te)) Collect(te, info, seen, depth + 1);
            }
        }
    }

    // 計算 feature 的值。regs：暫存器位址 → 讀到的 32 位元值（8 位元組暫存器用 address 與 address+4）
    public GenEvalResult Evaluate(string name, Dictionary<ulong, uint> regs) {
        GenEvalResult res = new GenEvalResult();
        try {
            XmlElement e;
            if (!nodes.TryGetValue(name, out e)) throw new Exception("XML 中找不到 " + name);
            double v = EvalNode(e, regs, 0);
            res.Ok = true; res.Value = v; res.Raw = (long)Math.Truncate(v);
            res.Text = v.ToString(CultureInfo.InvariantCulture);
            if (e.LocalName == "Enumeration") {
                foreach (XmlElement ee in Children(e, "EnumEntry")) {
                    string ev = Child(ee, "Value");
                    if (ev != null && ParseInt(ev) == res.Raw) { res.Text = ee.GetAttribute("Name"); break; }
                }
            } else if (e.LocalName == "Boolean") {
                string on = Child(e, "OnValue");
                long onv = on != null ? ParseInt(on) : 1;
                res.Text = res.Raw == onv ? "True" : "False";
            }
        } catch (Exception ex) { res.Ok = false; res.Error = ex.Message; }
        return res;
    }

    public static long RegisterValue(GenRegister r, Dictionary<ulong, uint> regs) {
        uint w0;
        if (!regs.TryGetValue(r.Address, out w0)) throw new Exception(string.Format("暫存器 0x{0:X8} 沒有讀到", r.Address));
        ulong raw;
        int bits;
        if (r.Length == 8) {
            uint w1;
            if (!regs.TryGetValue(r.Address + 4, out w1)) throw new Exception(string.Format("暫存器 0x{0:X8} 沒有讀到", r.Address + 4));
            raw = r.BigEndian ? (((ulong)w0 << 32) | w1) : (((ulong)w1 << 32) | w0);
            bits = 64;
        } else {
            raw = w0; bits = 32;
            if (!r.BigEndian) {          // READREG 讀到的是網路位元組順序，小端暫存器要反轉
                raw = ((w0 & 0xFF) << 24) | ((w0 & 0xFF00) << 8) | ((w0 >> 8) & 0xFF00) | (w0 >> 24);
            }
        }
        if (r.Lsb >= 0) {
            int shift, width;
            if (r.BigEndian) { shift = (bits - 1) - r.Lsb; width = r.Lsb - r.Msb + 1; }
            else { shift = r.Lsb; width = r.Msb - r.Lsb + 1; }
            if (width <= 0 || shift < 0) throw new Exception(r.Node + " 的 LSB/MSB 設定無法解讀");
            ulong mask = width >= 64 ? ulong.MaxValue : ((1UL << width) - 1);
            ulong v = (raw >> shift) & mask;
            if (r.Signed && width < 64 && (v & (1UL << (width - 1))) != 0) return (long)v - (1L << width);
            return (long)v;
        }
        if (r.Signed) {
            if (bits == 32) return (int)(uint)raw;
            return (long)raw;
        }
        return (long)raw;
    }

    double EvalNode(XmlElement e, Dictionary<ulong, uint> regs, int depth) {
        if (depth > 16) throw new Exception("XML 節點遞迴太深：" + e.GetAttribute("Name"));
        string t = e.LocalName;
        switch (t) {
            case "IntReg":
            case "MaskedIntReg":
            case "StructEntry": {
                GenRegister r = MakeRegister(e);
                if (r == null) throw new Exception(e.GetAttribute("Name") + " 沒有位址");
                return RegisterValue(r, regs);
            }
            case "FloatReg": {
                GenRegister r = MakeRegister(e);
                uint w;
                if (!regs.TryGetValue(r.Address, out w)) throw new Exception(string.Format("暫存器 0x{0:X8} 沒有讀到", r.Address));
                byte[] b = BitConverter.GetBytes(w);       // 小端排列的 w
                if (!r.BigEndian) Array.Reverse(b);
                if (r.Length == 4) return BitConverter.ToSingle(b, 0);
                throw new NotSupportedException("8 位元組 FloatReg 目前不支援");
            }
            case "SwissKnife":
            case "IntSwissKnife":
            case "Converter":
            case "IntConverter": {
                Dictionary<string, double> vars = new Dictionary<string, double>(StringComparer.Ordinal);
                foreach (XmlElement pv in Children(e, "pVariable")) {
                    string vn = pv.GetAttribute("Name");
                    XmlElement te;
                    if (!nodes.TryGetValue(pv.InnerText.Trim(), out te)) throw new Exception("找不到變數節點 " + pv.InnerText.Trim());
                    vars[vn] = EvalNode(te, regs, depth + 1);
                }
                foreach (XmlElement c in Children(e, "Constant")) vars[c.GetAttribute("Name")] = ParseNum(c.InnerText);
                foreach (XmlElement c in Children(e, "Expression")) vars[c.GetAttribute("Name")] = GenFormula.Eval(c.InnerText, vars);
                if (t == "SwissKnife" || t == "IntSwissKnife") {
                    double v = GenFormula.Eval(Child(e, "Formula"), vars);
                    return t == "IntSwissKnife" ? Math.Truncate(v) : v;
                }
                string pval = Child(e, "pValue");
                XmlElement raw;
                if (pval == null || !nodes.TryGetValue(pval, out raw)) throw new Exception(e.GetAttribute("Name") + " 沒有 pValue");
                // FormulaFrom：暫存器的值叫 TO，算出來的是 feature 的值（FROM）
                vars["TO"] = EvalNode(raw, regs, depth + 1);
                double r2 = GenFormula.Eval(Child(e, "FormulaFrom"), vars);
                return t == "IntConverter" ? Math.Truncate(r2) : r2;
            }
            default: {
                // Integer / Float / Enumeration / Boolean / Command 等：Value 或 pValue
                string pv = Child(e, "pValue");
                if (pv != null) {
                    XmlElement te;
                    if (!nodes.TryGetValue(pv, out te)) throw new Exception("找不到節點 " + pv);
                    return EvalNode(te, regs, depth + 1);
                }
                string v = Child(e, "Value");
                if (v != null) return ParseNum(v);
                throw new Exception(e.GetAttribute("Name") + "（" + t + "）沒有 Value 或 pValue");
            }
        }
    }

    // 取得 Integer 的 Min / Max / Inc（常數或指向其他節點）
    public double? Limit(string name, string which, Dictionary<ulong, uint> regs) {
        XmlElement e;
        if (!nodes.TryGetValue(name, out e)) return null;
        string c = Child(e, which);
        if (c != null) return ParseNum(c);
        string p = Child(e, "p" + which);
        XmlElement te;
        if (p != null && nodes.TryGetValue(p, out te)) return EvalNode(te, regs, 0);
        // 經由 pValue 指到的節點上也可能定義
        string pv = Child(e, "pValue");
        if (pv != null && nodes.TryGetValue(pv, out te)) {
            c = Child(te, which);
            if (c != null) return ParseNum(c);
        }
        return null;
    }

    // Min / Max / Inc 需要讀哪些暫存器
    public List<GenRegister> LimitRegisters(string name) {
        List<GenRegister> list = new List<GenRegister>();
        XmlElement e;
        if (!nodes.TryGetValue(name, out e)) return list;
        foreach (string w in new string[] { "pMin", "pMax", "pInc" }) {
            string p = Child(e, w);
            if (p == null) continue;
            GenFeatureInfo fi = Resolve(p);
            list.AddRange(fi.Registers);
        }
        return list;
    }
}
