using System.Collections.Concurrent;

namespace NetStutter.Probe;

/// <summary>In-memory sample/spike store — mirrors Serve-SpikeTimeline.DataStore.</summary>
internal sealed class DataStore
{
    public readonly object Lock = new();
    public readonly List<SamplePoint> Samples = new();
    public readonly List<SpikePoint> Spikes = new();
    public readonly ConcurrentQueue<string> Events = new();
    public double? Anchor;
    public long Sent;
    public long Slow;
    public long LargeCount;
    public bool Recording;
    public string ProbeError = "";
    public readonly double Started = Constants.NowMs();

    private readonly List<double> _dur = new();
    private readonly List<int> _count = new();
    private bool _clumpsDirty;
    private readonly Dictionary<int, double> _segThr = new();
    private const int MaxEvents = 200;

    public void AddEvent(string line)
    {
        Events.Enqueue(line);
        while (Events.Count > MaxEvents && Events.TryDequeue(out _)) { }
    }

    public void Trim(double tNow)
    {
        var cut = tNow - Constants.KeepMs;
        if (Samples.Count > 0 && Samples[0].T < cut)
        {
            var lo = 0;
            while (lo < Samples.Count && Samples[lo].T < cut) lo++;
            if (lo > 0)
            {
                Samples.RemoveRange(0, lo);
                _segThr.Clear();
            }
        }
        if (Spikes.Count > 0 && Spikes[0].T < cut)
        {
            var lo = 0;
            while (lo < Spikes.Count && Spikes[lo].T < cut) lo++;
            if (lo > 0)
            {
                Spikes.RemoveRange(0, lo);
                _clumpsDirty = true;
            }
        }
    }

    public void AddSample(double t, double rtt, string flow = "")
    {
        Samples.Add(new SamplePoint { T = t, Rtt = rtt, Flow = flow });
        Trim(t);
    }

    public void AddSpike(double t, double rtt, string flow, bool large)
    {
        Spikes.Add(new SpikePoint { T = t, Rtt = rtt, Large = large, Flow = flow });
        if (Anchor is null && large)
        {
            Anchor = t;
            _segThr.Clear();
        }
        _clumpsDirty = true;
        _dur.Add(1);
        _count.Add(1);
        Trim(t);
        if (large) LargeCount++;
        Slow++;
        var hh = DateTimeOffset.FromUnixTimeMilliseconds((long)t).ToLocalTime().ToString("HH:mm:ss.fff");
        AddEvent($"{hh}  {flow}  {rtt:F1}ms{(large ? "  LARGE" : "")}");
    }

    public (double T0, double T1) Bounds()
    {
        double? min = null, max = null;
        void consider(double t)
        {
            min = min is null ? t : Math.Min(min.Value, t);
            max = max is null ? t : Math.Max(max.Value, t);
        }
        if (Samples.Count > 0)
        {
            consider(Samples[0].T);
            consider(Samples[^1].T);
        }
        if (Spikes.Count > 0)
        {
            consider(Spikes[0].T);
            consider(Spikes[^1].T);
        }
        if (min is null || max is null)
        {
            var n = Constants.NowMs();
            return (n - 60_000, n);
        }
        return (min.Value, max.Value);
    }

    private int SampleIndexAtOrAfter(double t)
    {
        var lo = 0;
        var hi = Samples.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (Samples[mid].T < t) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    private int? SegIndex(double t)
    {
        if (Anchor is null) return null;
        return (int)Math.Floor((t - Anchor.Value) / (Constants.CycleSec * 1000.0));
    }

    private double SegmentThreshold(int segIdx)
    {
        if (Anchor is null || segIdx < 0) return Constants.HighlightMs;
        var curIdx = Samples.Count > 0 ? SegIndex(Samples[^1].T) : null;
        var cacheable = curIdx is not null && segIdx < curIdx;
        if (cacheable && _segThr.TryGetValue(segIdx, out var cached)) return cached;

        var cycle = Constants.CycleSec * 1000.0;
        var a0 = Anchor.Value + segIdx * cycle;
        var a1 = a0 + cycle;
        var i = SampleIndexAtOrAfter(a0);
        var xs = new List<double>();
        while (i < Samples.Count && Samples[i].T < a1)
        {
            xs.Add(Samples[i].Rtt);
            i++;
        }

        double thr;
        if (xs.Count < Constants.MinSegSamples)
        {
            thr = Constants.HighlightMs;
        }
        else
        {
            var mean = xs.Average();
            var std = Math.Sqrt(xs.Sum(x => (x - mean) * (x - mean)) / xs.Count);
            thr = mean + Math.Max(std, 5.0);
        }
        if (cacheable) _segThr[segIdx] = thr;
        return thr;
    }

    public double OutlierThreshold(double t)
    {
        var idx = SegIndex(t);
        if (idx is null || idx < 1) return Constants.HighlightMs;
        return SegmentThreshold(idx.Value - 1);
    }

    public bool IsOutlier(double t, double rtt)
    {
        if (rtt >= Constants.LargeMs) return true;
        return rtt > Math.Max(OutlierThreshold(t), Constants.HighlightMs);
    }

    public List<SpikePoint> SamplePeakHighlights(double t0, double t1)
    {
        var outList = new List<SpikePoint>();
        if (Samples.Count == 0 || t1 <= t0) return outList;
        var pad = Constants.CycleSec * 1000.0;
        var i0 = Math.Max(0, SampleIndexAtOrAfter(t0 - pad) - 1);
        var i1 = Math.Min(Samples.Count, SampleIndexAtOrAfter(t1 + 1.0) + 1);
        for (var i = Math.Max(1, i0 + 1); i < Math.Min(i1, Samples.Count - 1); i++)
        {
            var s = Samples[i];
            if (s.T < t0 || s.T > t1) continue;
            var rtt = s.Rtt;
            if (rtt < Samples[i - 1].Rtt || rtt < Samples[i + 1].Rtt) continue;
            if (!IsOutlier(s.T, rtt)) continue;
            var large = rtt >= Constants.LargeMs;
            outList.Add(new SpikePoint
            {
                T = s.T,
                Rtt = rtt,
                Large = large,
                Minor = !large,
                Flow = s.Flow,
            });
        }
        return outList;
    }

    public List<SamplePoint> SamplesIn(double t0, double t1, int budget = 1200)
    {
        var outList = new List<SamplePoint>();
        if (Samples.Count == 0 || t1 <= t0) return outList;
        var lo = SampleIndexAtOrAfter(t0);
        var span = t1 - t0;
        var bucket = Math.Max(1.0, span / Math.Max(1, budget));
        int? bstart = null;
        double bmax = 0, bmid = 0;
        var i = lo;
        while (i < Samples.Count && Samples[i].T <= t1)
        {
            var t = Samples[i].T;
            var rtt = Samples[i].Rtt;
            var b = (int)Math.Floor((t - t0) / bucket);
            if (b != bstart)
            {
                if (bstart is not null)
                    outList.Add(new SamplePoint { T = bmid, Rtt = bmax });
                bstart = b;
                bmax = rtt;
                bmid = t;
            }
            else if (rtt > bmax)
            {
                bmax = rtt;
                bmid = t;
            }
            i++;
        }
        if (bstart is not null)
            outList.Add(new SamplePoint { T = bmid, Rtt = bmax });
        return outList;
    }

    public List<SpikePoint> SpikesIn(double t0, double t1, int budget = 400)
    {
        EnsureClumps();
        var outList = new List<SpikePoint>();
        var lo = 0;
        var hi = Spikes.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (Spikes[mid].T < t0) lo = mid + 1;
            else hi = mid;
        }
        var i = lo;
        while (i < Spikes.Count && Spikes[i].T <= t1)
        {
            var s = Spikes[i];
            if (s.Large || IsOutlier(s.T, s.Rtt) || s.Rtt >= Constants.HighlightMs)
            {
                outList.Add(new SpikePoint
                {
                    T = s.T,
                    Rtt = s.Rtt,
                    Large = s.Large,
                    Minor = !s.Large && s.Rtt < Constants.LargeMs,
                    Flow = s.Flow,
                    DurMs = i < _dur.Count ? _dur[i] : 1,
                    Count = i < _count.Count ? _count[i] : 1,
                });
            }
            i++;
        }

        const double nearMs = 40.0;
        foreach (var peak in SamplePeakHighlights(t0, t1))
        {
            if (outList.Any(x => Math.Abs(x.T - peak.T) <= nearMs)) continue;
            outList.Add(peak);
        }
        outList.Sort((a, b) => a.T.CompareTo(b.T));
        if (outList.Count > budget)
        {
            var step = (int)Math.Ceiling(outList.Count / (double)budget);
            var kept = new List<SpikePoint>();
            for (var k = 0; k < outList.Count; k++)
            {
                if (outList[k].Large || k % step == 0) kept.Add(outList[k]);
            }
            outList = kept;
        }
        return outList;
    }

    public List<(double T, bool Hit)> SlotOutcomes()
    {
        var outList = new List<(double, bool)>();
        if (Anchor is null) return outList;
        var cycle = Constants.CycleSec * 1000.0;
        var tip = Constants.NowMs();
        var finalizeAfter = Constants.OnTimeMs + 600.0;
        var larges = Spikes.Where(s => s.Large || s.Rtt >= Constants.LargeMs).Select(s => s.T).ToList();
        var s = Anchor.Value;
        var guard = 0;
        var li = 0;
        while (s + finalizeAfter < tip && guard < 20000)
        {
            guard++;
            bool hit;
            if (Math.Abs(s - Anchor.Value) < 0.5) hit = true;
            else
            {
                while (li < larges.Count && larges[li] < s - Constants.OnTimeMs) li++;
                hit = li < larges.Count && larges[li] <= s + Constants.OnTimeMs;
            }
            outList.Add((s, hit));
            s += cycle;
        }
        return outList;
    }

    private void EnsureClumps()
    {
        if (!_clumpsDirty && _dur.Count == Spikes.Count) return;
        _dur.Clear();
        _count.Clear();
        var n = Spikes.Count;
        var i = 0;
        while (i < n)
        {
            var j = i;
            while (j + 1 < n && (Spikes[j + 1].T - Spikes[j].T) <= Constants.ClumpGapMs) j++;
            var dur = Math.Max(1.0, Spikes[j].T - Spikes[i].T);
            var cnt = j - i + 1;
            for (var k = i; k <= j; k++)
            {
                _dur.Add(dur);
                _count.Add(cnt);
            }
            i = j + 1;
        }
        _clumpsDirty = false;
    }

    public string StatusText()
    {
        var elapsed = (Constants.NowMs() - Started) / 1000.0;
        var rec = Recording ? "recording" : "idle";
        var err = string.IsNullOrEmpty(ProbeError) ? "" : $"\nerror={ProbeError}";
        return $"status={rec}\nmode=native\nelapsed_s={elapsed:F1}\nsent={Sent}\nslow={Slow}\nlarge={LargeCount}{err}";
    }
}
