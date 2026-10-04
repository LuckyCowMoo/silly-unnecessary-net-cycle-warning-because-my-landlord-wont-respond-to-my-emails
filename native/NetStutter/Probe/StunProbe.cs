using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace NetStutter.Probe;

/// <summary>
/// Persistent UDP STUN flows at RATE_HZ — same algorithm as Serve-SpikeTimeline.StunProbe.
/// Runs while the native window is open (Active=true).
/// </summary>
internal sealed class StunProbe : IDisposable
{
    private readonly DataStore _store;
    private readonly CancellationTokenSource _cts = new();
    private Thread? _thread;
    private volatile bool _active = true;
    private volatile int _rateHz = Constants.DefaultRateHz;

    public StunProbe(DataStore store) => _store = store;

    /// <summary>When false, probe sleeps (same as browser-tab idle). Native app keeps this true while shown.</summary>
    public bool Active
    {
        get => _active;
        set => _active = value;
    }

    /// <summary>STUN poll rate (Hz). Safe to change while running — next tick picks it up.</summary>
    public int RateHz
    {
        get => _rateHz;
        set
        {
            var v = value;
            if (v < 30) v = 30;
            if (v > 240) v = 240;
            if (v == _rateHz) return;
            _rateHz = v;
            lock (_store.Lock)
                _store.AddEvent($"probe: rate set to {v}Hz");
        }
    }

    public void Start()
    {
        if (_thread is not null) return;
        _thread = new Thread(Run) { IsBackground = true, Name = "stun-probe", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _thread?.Join(2000);
        _cts.Dispose();
    }

    private static byte[] StunRequest(out byte[] tid)
    {
        tid = new byte[12];
        Random.Shared.NextBytes(tid);
        var pkt = new byte[20];
        pkt[1] = 0x01;
        Buffer.BlockCopy(Constants.Magic, 0, pkt, 4, 4);
        Buffer.BlockCopy(tid, 0, pkt, 8, 12);
        return pkt;
    }

    private static byte[]? StunTid(byte[] data)
    {
        if (data.Length < 20) return null;
        var tid = new byte[12];
        Buffer.BlockCopy(data, 8, tid, 0, 12);
        return tid;
    }

    private static List<byte[]> Drain(Socket sock)
    {
        var outList = new List<byte[]>();
        var buf = new byte[2048];
        while (true)
        {
            try
            {
                if (sock.Available <= 0) break;
                var n = sock.Receive(buf);
                if (n <= 0) break;
                var copy = new byte[n];
                Buffer.BlockCopy(buf, 0, copy, 0, n);
                outList.Add(copy);
            }
            catch (SocketException)
            {
                break;
            }
        }
        return outList;
    }

    private sealed class Flow
    {
        public required string Name;
        public required Socket Sock;
        public readonly Dictionary<string, long> Pending = new(); // tid hex → stopwatch ticks at send
    }

    private static string TidKey(byte[] tid) => Convert.ToHexString(tid);

    private void Run()
    {
        var flows = new List<Flow>();
        try
        {
            foreach (var (host, port) in Constants.StunServers)
            {
                try
                {
                    var entry = Dns.GetHostEntry(host);
                    var addr = entry.AddressList.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                    if (addr is null) continue;
                    var sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                    try
                    {
                        sock.ReceiveBufferSize = 256 * 1024;
                        sock.SendBufferSize = 256 * 1024;
                    }
                    catch { /* ignore */ }
                    sock.Blocking = false;
                    sock.Connect(new IPEndPoint(addr, port));
                    flows.Add(new Flow { Name = host, Sock = sock });
                }
                catch (Exception ex)
                {
                    lock (_store.Lock) _store.ProbeError = $"{host}: {ex.Message}";
                }
            }

            if (flows.Count == 0)
            {
                lock (_store.Lock)
                {
                    _store.ProbeError = "no STUN servers reachable";
                    _store.AddEvent("probe: no STUN servers reachable");
                }
                return;
            }

            lock (_store.Lock)
                _store.AddEvent($"probe: {flows.Count} STUN flow(s) @ {_rateHz}Hz");

            var nextTick = Stopwatch.GetTimestamp();
            var freq = (double)Stopwatch.Frequency;

            while (!_cts.IsCancellationRequested)
            {
                var active = _active;
                lock (_store.Lock) _store.Recording = active;
                if (!active)
                {
                    Thread.Sleep(200);
                    nextTick = Stopwatch.GetTimestamp();
                    continue;
                }

                var rate = Math.Max(30, _rateHz);
                var interval = 1.0 / rate;

                var batchSamples = new List<(double T, double Rtt, string Flow)>();
                var batchSpikes = new List<(double T, double Rtt, string Flow, bool Large)>();

                void TakeReplies()
                {
                    var nowPerf = Stopwatch.GetTimestamp();
                    foreach (var f in flows)
                    {
                        foreach (var data in Drain(f.Sock))
                        {
                            var tid = StunTid(data);
                            if (tid is null) continue;
                            var key = TidKey(tid);
                            if (!f.Pending.Remove(key, out var sentAt)) continue;
                            var recvT = Stopwatch.GetTimestamp();
                            var rtt = Math.Round((recvT - sentAt) / freq * 1000.0, 1);
                            if (rtt < 0 || rtt > 5000) continue;
                            var tWall = Constants.NowMs();
                            batchSamples.Add((tWall, rtt, f.Name));
                            if (rtt >= Constants.SpikeMs)
                                batchSpikes.Add((tWall, rtt, f.Name, rtt >= Constants.LargeMs));
                        }
                        var dead = f.Pending
                            .Where(kv => (nowPerf - kv.Value) / freq * 1000.0 > Constants.TimeoutMs)
                            .Select(kv => kv.Key)
                            .ToList();
                        foreach (var k in dead) f.Pending.Remove(k);
                    }
                }

                // Drain first (catch replies that arrived during sleep), then send — same as Python.
                TakeReplies();
                foreach (var f in flows)
                {
                    try
                    {
                        var pkt = StunRequest(out var tid);
                        var sendT = Stopwatch.GetTimestamp();
                        f.Sock.Send(pkt);
                        f.Pending[TidKey(tid)] = sendT;
                        lock (_store.Lock) _store.Sent++;
                    }
                    catch (SocketException) { /* ignore */ }
                }
                TakeReplies();

                if (batchSamples.Count > 0 || batchSpikes.Count > 0)
                {
                    lock (_store.Lock)
                    {
                        // One spike + one sample per tick = worst among the 3 flows.
                        // Logging every flow produced stacked twin markers on one event.
                        if (batchSpikes.Count > 0)
                        {
                            var peakSpike = batchSpikes.MaxBy(x => x.Rtt);
                            _store.AddSpike(peakSpike.T, peakSpike.Rtt, peakSpike.Flow, peakSpike.Large);
                        }
                        if (batchSamples.Count > 0)
                        {
                            var peak = batchSamples.MaxBy(x => x.Rtt);
                            _store.AddSample(peak.T, peak.Rtt, peak.Flow);
                        }
                    }
                }

                nextTick += (long)(interval * freq);
                var delayTicks = nextTick - Stopwatch.GetTimestamp();
                if (delayTicks > 0)
                {
                    var ms = delayTicks / freq * 1000.0;
                    if (ms > 0) Thread.Sleep(TimeSpan.FromMilliseconds(ms));
                }
                else
                {
                    // fell behind — resync so we don't spin
                    nextTick = Stopwatch.GetTimestamp();
                }
            }
        }
        finally
        {
            foreach (var f in flows)
            {
                try { f.Sock.Dispose(); } catch { /* ignore */ }
            }
            lock (_store.Lock) _store.Recording = false;
        }
    }
}
