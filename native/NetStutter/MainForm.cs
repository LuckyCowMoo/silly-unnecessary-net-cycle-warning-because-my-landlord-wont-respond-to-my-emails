using System.Drawing.Drawing2D;
using NetStutter.Probe;

namespace NetStutter;

internal sealed class MainForm : Form
{
    private readonly DataStore _store;
    private readonly StunProbe _probe;

    private readonly Panel _map = new() { Dock = DockStyle.Top, Height = 52 };
    private readonly Panel _main = new() { Dock = DockStyle.Fill };
    private readonly Panel _bin = new() { Dock = DockStyle.Bottom, Height = 28 };
    private readonly Label _title = new();
    private readonly Label _stats = new();
    private readonly Label _next = new();
    private readonly Label _tally = new();
    private readonly Label _clockLabel = new();
    private readonly Label _nowClock = new(); // large current time, top center
    private readonly Panel _clock = new() { Width = 56, Height = 56 };
    private readonly Font _nowFont = new("Consolas", 28f, FontStyle.Bold);
    private readonly Button _liveBtn = new();
    private readonly Button _followBtn = new();
    private readonly Button _soundBtn = new();
    private readonly TrackBar _rateSlider = new();
    private readonly Label _rateLabel = new();

    private bool _live = true;
    private bool _follow = true;
    private bool _sound;
    private double _v0, _v1;
    private double _lastFollowNow;
    private readonly Dictionary<double, bool> _slotHits = new();
    private readonly Dictionary<double, bool> _slotResults = new();
    private readonly Dictionary<double, bool> _peakMarks = new(); // t → large
    private List<SamplePoint> _viewSamples = new();
    private List<SpikePoint> _viewSpikes = new();
    private Point? _dragStart;
    private double _dragV0, _dragV1;

    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 33 };
    private readonly Font _mono = new("Consolas", 8.5f);
    private readonly Font _ui = new("Segoe UI", 9f);

    private const int LeftGutter = 44;
    private static readonly Color Bg = Color.FromArgb(0x0b, 0x0e, 0x12);
    private static readonly Color Grid = Color.FromArgb(0x24, 0x30, 0x41);
    private static readonly Color Line = Color.FromArgb(0x4a, 0x90, 0xa4);
    private static readonly Color Blue = Color.FromArgb(0x4a, 0x90, 0xd9);
    private static readonly Color Red = Color.FromArgb(0xe8, 0x5d, 0x4c);
    private static readonly Color Green = Color.FromArgb(0x7d, 0xce, 0xa0);
    private static readonly Color Amber = Color.FromArgb(0xe0, 0xa1, 0x4a);
    private static readonly Color Dim = Color.FromArgb(0x5a, 0x6a, 0x7a);

    // warn audio (same arming / hit-miss rules as timeline-web tickWarnAudio)
    private double? _audioTarget;
    private readonly HashSet<string> _beeped = new();
    private bool _audioResolved;

    public MainForm(DataStore store, StunProbe probe)
    {
        _store = store;
        _probe = probe;
        Text = "Net Stutter — native probe";
        Width = 1280;
        Height = 800;
        MinimumSize = new Size(900, 560);
        BackColor = Bg;
        ForeColor = Color.FromArgb(0xcf, 0xd8, 0xe3);
        Font = _ui;
        DoubleBuffered = true;

        BuildChrome();
        foreach (var p in new[] { _map, _main, _bin, _clock })
        {
            p.BackColor = Bg;
            typeof(Panel).InvokeMember("DoubleBuffered",
                System.Reflection.BindingFlags.SetProperty | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic,
                null, p, new object[] { true });
        }

        _map.Paint += (_, e) => DrawMap(e.Graphics, _map.ClientSize);
        _main.Paint += (_, e) => DrawMain(e.Graphics, _main.ClientSize);
        _bin.Paint += (_, e) => DrawBin(e.Graphics, _bin.ClientSize);
        _clock.Paint += (_, e) => DrawClock(e.Graphics, _clock.ClientSize);

        WireInput();
        SetLiveWindow();
        _uiTimer.Tick += (_, _) => TickUi();
        _uiTimer.Start();
        FormClosed += (_, _) =>
        {
            _probe.Active = false;
            _uiTimer.Stop();
        };
        Shown += (_, _) => _probe.Active = true;
    }

    private void BuildChrome()
    {
        var top = new Panel { Dock = DockStyle.Top, Height = 96, BackColor = Bg };
        top.Resize += (_, _) => LayoutNowClock(top);

        _title.AutoSize = true;
        _title.Location = new Point(10, 8);
        _title.ForeColor = Color.White;
        _stats.AutoSize = true;
        _stats.Location = new Point(10, 32);
        _stats.ForeColor = Dim;
        _stats.Font = _mono;
        _next.AutoSize = true;
        _next.Location = new Point(10, 54);
        _next.ForeColor = Green;
        _next.Font = _mono;
        _next.MaximumSize = new Size(420, 0);

        _nowClock.AutoSize = false;
        _nowClock.Font = _nowFont;
        _nowClock.ForeColor = Color.White;
        _nowClock.TextAlign = ContentAlignment.MiddleCenter;
        _nowClock.BackColor = Bg;
        _nowClock.Text = DateTime.Now.ToString("HH:mm:ss");
        _nowClock.Width = 220;
        _nowClock.Height = 48;

        foreach (var b in new[] { _liveBtn, _followBtn, _soundBtn })
        {
            b.FlatStyle = FlatStyle.Flat;
            b.ForeColor = Color.White;
            b.BackColor = Color.FromArgb(0x1a, 0x22, 0x2e);
            b.Height = 30;
            b.Margin = new Padding(0);
            b.Padding = new Padding(0);
            b.Cursor = Cursors.Hand;
            b.AutoSize = false;
            b.TextAlign = ContentAlignment.MiddleCenter;
        }
        _liveBtn.Width = 108;
        _followBtn.Width = 108;
        _soundBtn.Width = 88;
        _liveBtn.Click += (_, _) =>
        {
            if (_live && _follow) { _live = false; _lastFollowNow = Constants.NowMs(); UpdateFollowBtns(); }
            else SetLiveWindow();
        };
        _followBtn.Click += (_, _) =>
        {
            if (_live && _follow) { _live = false; _lastFollowNow = Constants.NowMs(); }
            else { _follow = !_follow; if (_follow) { _live = false; _lastFollowNow = Constants.NowMs(); } }
            UpdateFollowBtns();
        };
        _soundBtn.Click += (_, _) => { _sound = !_sound; UpdateFollowBtns(); };

        // Fixed right cluster: buttons + rate slider + countdown clock.
        var right = new Panel
        {
            Dock = DockStyle.Right,
            Width = 420,
            BackColor = Bg,
            Padding = new Padding(8, 10, 12, 8),
        };
        _clockLabel.AutoSize = false;
        _clockLabel.Width = 64;
        _clockLabel.Height = 16;
        _clockLabel.ForeColor = Color.White;
        _clockLabel.Font = _mono;
        _clockLabel.TextAlign = ContentAlignment.MiddleCenter;
        _clock.SetBounds(0, 0, 56, 56);
        var clockWrap = new Panel { Width = 64, Height = 76, Left = 340, Top = 6 };
        _clock.Left = 4;
        _clockLabel.Top = 58;
        _clockLabel.Left = 0;
        clockWrap.Controls.Add(_clock);
        clockWrap.Controls.Add(_clockLabel);

        _liveBtn.SetBounds(8, 8, 108, 28);
        _followBtn.SetBounds(122, 8, 108, 28);
        _soundBtn.SetBounds(236, 8, 88, 28);

        _rateLabel.AutoSize = false;
        _rateLabel.SetBounds(8, 42, 80, 18);
        _rateLabel.Font = _mono;
        _rateLabel.ForeColor = Dim;
        _rateLabel.Text = "Rate 60Hz";

        _rateSlider.SetBounds(90, 38, 234, 30);
        _rateSlider.Minimum = 0;
        _rateSlider.Maximum = Constants.RateChoices.Length - 1;
        _rateSlider.TickFrequency = 1;
        _rateSlider.TickStyle = TickStyle.BottomRight;
        _rateSlider.SmallChange = 1;
        _rateSlider.LargeChange = 1;
        _rateSlider.Value = Array.IndexOf(Constants.RateChoices, Constants.DefaultRateHz);
        if (_rateSlider.Value < 0) _rateSlider.Value = 0;
        _rateSlider.BackColor = Bg;
        _rateSlider.ValueChanged += (_, _) =>
        {
            var hz = Constants.RateChoices[_rateSlider.Value];
            _probe.RateHz = hz;
            _rateLabel.Text = $"Rate {hz}Hz";
        };

        right.Controls.Add(_liveBtn);
        right.Controls.Add(_followBtn);
        right.Controls.Add(_soundBtn);
        right.Controls.Add(_rateLabel);
        right.Controls.Add(_rateSlider);
        right.Controls.Add(clockWrap);

        top.Controls.Add(right);
        top.Controls.Add(_nowClock);
        top.Controls.Add(_title);
        top.Controls.Add(_stats);
        top.Controls.Add(_next);
        LayoutNowClock(top);

        _tally.Dock = DockStyle.Bottom;
        _tally.Height = 54;
        _tally.Font = _mono;
        _tally.ForeColor = Color.FromArgb(0x9a, 0xaa, 0xbb);
        _tally.Padding = new Padding(8, 4, 8, 4);

        Controls.Add(_main);
        Controls.Add(_bin);
        Controls.Add(_map);
        Controls.Add(_tally);
        Controls.Add(top);
        UpdateFollowBtns();
    }

    private void LayoutNowClock(Control top)
    {
        // Keep the big clock visually centered in the header (accounting for right cluster).
        const int rightW = 420;
        var avail = Math.Max(200, top.ClientSize.Width - rightW);
        _nowClock.Left = Math.Max(0, (avail - _nowClock.Width) / 2);
        _nowClock.Top = (top.ClientSize.Height - _nowClock.Height) / 2;
    }

    private void UpdateFollowBtns()
    {
        _liveBtn.BackColor = _live && _follow ? Color.FromArgb(0x1e, 0x84, 0x49) : Color.FromArgb(0x1a, 0x22, 0x2e);
        _liveBtn.Text = _live && _follow ? "Live  ON" : "Live";
        _followBtn.BackColor = _follow ? Color.FromArgb(0x2e, 0x6e, 0xb5) : Color.FromArgb(0x1a, 0x22, 0x2e);
        _followBtn.Text = _follow ? "Scroll  ON" : "Scroll";
        _soundBtn.BackColor = _sound ? Color.FromArgb(0x8e, 0x44, 0xad) : Color.FromArgb(0x1a, 0x22, 0x2e);
        _soundBtn.Text = _sound ? "Sound ON" : "Sound";
    }

    private double FollowTipMs()
    {
        lock (_store.Lock)
        {
            if (_store.Recording) return Constants.NowMs();
            var (t0, t1) = _store.Bounds();
            if (t1 > t0 && t1 > 1e12) return t1;
        }
        return Constants.NowMs();
    }

    private void SetLiveWindow()
    {
        var tip = FollowTipMs();
        _v1 = tip + Constants.LiveAheadSec * 1000;
        _v0 = tip - Constants.LiveBackSec * 1000;
        _live = true;
        _follow = true;
        _lastFollowNow = Constants.NowMs();
        UpdateFollowBtns();
        RefreshViewData();
    }

    private void LeaveFollow()
    {
        _follow = false;
        _live = false;
        UpdateFollowBtns();
    }

    private static float XOf(double t, double v0, double v1, int w, int left = LeftGutter)
    {
        var span = v1 - v0;
        if (span <= 0) return left;
        return left + (float)((t - v0) / span * (w - left - 10));
    }

    private static double TOf(float x, double v0, double v1, int w, int left = LeftGutter)
    {
        var span = v1 - v0;
        var frac = (x - left) / Math.Max(1, w - left - 10);
        return v0 + frac * span;
    }

    private (double M0, double M1) MapRange(double t0, double t1)
    {
        var m0 = t0;
        var m1 = t1;
        if (_v1 > _v0)
        {
            if (!(m1 > m0)) { m0 = _v0; m1 = _v1; }
            else { m0 = Math.Min(m0, _v0); m1 = Math.Max(m1, _v1); }
        }
        return (m0, m1);
    }

    private bool MajorOnTime(double slotT)
    {
        if (_slotHits.TryGetValue(slotT, out var hit) && hit) return true;
        foreach (var s in _viewSpikes)
        {
            if (Math.Abs(s.T - slotT) > Constants.OnTimeMs) continue;
            if (s.Large || s.Rtt >= Constants.LargeMs)
            {
                _slotHits[slotT] = true;
                return true;
            }
        }
        return false;
    }

    private Color SlotColor(double slotT, double now)
    {
        if (slotT >= now) return Blue;
        if (MajorOnTime(slotT) || (_slotResults.TryGetValue(slotT, out var h) && h)) return Red;
        if (_slotResults.TryGetValue(slotT, out var miss) && !miss) return Green;
        return Dim;
    }

    private void UpdateSlotResults(double? anchor)
    {
        if (anchor is null) return;
        var cycle = Constants.CycleSec * 1000;
        var tip = FollowTipMs();
        var finalizeAfter = Constants.OnTimeMs + 600;
        _slotResults[anchor.Value] = true;
        _slotHits[anchor.Value] = true;
        var s = anchor.Value + cycle;
        var guard = 0;
        while (s + finalizeAfter < tip && guard < 20000)
        {
            guard++;
            if (MajorOnTime(s)) _slotResults[s] = true;
            else if (!_slotResults.ContainsKey(s) && _viewSpikes.Count > 0)
            {
                var lo = _viewSpikes.Min(x => x.T);
                var hi = _viewSpikes.Max(x => x.T);
                if (s >= lo - Constants.OnTimeMs && s <= hi + Constants.OnTimeMs)
                    _slotResults[s] = false;
            }
            s += cycle;
        }
    }

    private void RememberPeak(double t, bool large)
    {
        if (_peakMarks.TryGetValue(t, out var prev) && prev) return;
        _peakMarks[t] = large || prev;
    }

    private void RefreshViewData()
    {
        List<SamplePoint> samples;
        List<SpikePoint> spikes;
        List<(double T, bool Hit)> outcomes;
        double? anchor;
        lock (_store.Lock)
        {
            var pad = Constants.CycleSec * 1000 + Constants.OnTimeMs;
            var samplePad = Constants.CycleSec * 1000;
            spikes = _store.SpikesIn(_v0 - pad, _v1 + pad, 800);
            samples = _store.SamplesIn(_v0 - samplePad, _v1, 3600);
            outcomes = _store.SlotOutcomes();
            anchor = _store.Anchor;
        }
        foreach (var o in outcomes)
        {
            _slotResults[o.T] = o.Hit;
            if (o.Hit) _slotHits[o.T] = true;
        }
        _viewSpikes = spikes;
        foreach (var s in _viewSpikes) RememberPeak(s.T, s.Large || s.Rtt >= Constants.LargeMs);

        // Sample-line peak marks (same rule as web): mean+1σ floored at 75ms
        MergeSamplePeaks(samples);
        _viewSamples = samples.Where(s => s.T >= _v0 && s.T <= _v1).ToList();
        UpdateSlotResults(anchor);
    }

    private void MergeSamplePeaks(List<SamplePoint> samples)
    {
        if (samples.Count < 3) return;
        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        if (anchor is null) return;
        var cycle = Constants.CycleSec * 1000;
        var thrCache = new Dictionary<int, double>();

        double Thr(double t)
        {
            var idx = (int)Math.Floor((t - anchor.Value) / cycle);
            if (idx < 1) return Constants.HighlightMs;
            var prev = idx - 1;
            if (thrCache.TryGetValue(prev, out var c)) return c;
            var a0 = anchor.Value + prev * cycle;
            var a1 = a0 + cycle;
            var xs = samples.Where(s => s.T >= a0 && s.T < a1).Select(s => s.Rtt).ToList();
            double thr = Constants.HighlightMs;
            if (xs.Count >= Constants.MinSegSamples)
            {
                var mean = xs.Average();
                var std = Math.Sqrt(xs.Sum(x => (x - mean) * (x - mean)) / xs.Count);
                thr = mean + Math.Max(std, 5);
            }
            thrCache[prev] = thr;
            return thr;
        }

        for (var i = 1; i < samples.Count - 1; i++)
        {
            var s = samples[i];
            if (s.T < _v0 || s.T > _v1) continue;
            var rtt = s.Rtt;
            if (rtt < samples[i - 1].Rtt || rtt < samples[i + 1].Rtt) continue;
            var large = rtt >= Constants.LargeMs;
            var thr = Math.Max(Thr(s.T), Constants.HighlightMs);
            if (!large && rtt <= thr) continue;
            if (_viewSpikes.Any(x => Math.Abs(x.T - s.T) <= 40))
            {
                RememberPeak(s.T, large);
                continue;
            }
            _viewSpikes.Add(new SpikePoint { T = s.T, Rtt = rtt, Large = large, Minor = !large });
            RememberPeak(s.T, large);
        }
        _viewSpikes = _viewSpikes.OrderBy(s => s.T).ToList();
    }

    private void TickUi()
    {
        var wall = Constants.NowMs();
        if (_follow)
        {
            if (_lastFollowNow <= 0) _lastFollowNow = wall;
            var dt = wall - _lastFollowNow;
            if (dt > 30)
            {
                if (_live)
                {
                    var tip = FollowTipMs();
                    _v1 = tip + Constants.LiveAheadSec * 1000;
                    _v0 = tip - Constants.LiveBackSec * 1000;
                }
                else
                {
                    _v0 += dt;
                    _v1 += dt;
                }
                _lastFollowNow = wall;
            }
        }

        lock (_store.Lock)
        {
            var (t0, t1) = _store.Bounds();
            var mode = _store.Recording
                ? (_follow ? (_live ? "LIVE" : "LIVE · SCROLLING") : "LIVE · PAUSED")
                : "IDLE";
            _title.Text = $"{mode}  |  native";
            _stats.Text = $"spikes {_store.Spikes.Count}  samples {_store.Samples.Count}  " +
                          $"view {(_v1 - _v0) / 60000:F2} min  data {(t1 - t0) / 60000:F1} min  " +
                          $"probe={_probe.RateHz}Hz  cycle={Constants.CycleSec}s";
        }

        _nowClock.Text = DateTime.Now.ToString("HH:mm:ss");
        RefreshViewData();
        RenderNextAndTally();
        TickWarnAudio();
        _map.Invalidate();
        _main.Invalidate();
        _bin.Invalidate();
        _clock.Invalidate();
    }

    private void RenderNextAndTally()
    {
        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        if (anchor is null)
        {
            _next.Text = "next: waiting for first major (≥200ms)";
        }
        else
        {
            var cycle = Constants.CycleSec * 1000;
            var n = Constants.NowMs();
            var k = Math.Ceiling((n - anchor.Value) / cycle);
            if (n - anchor.Value < 0) k = 0;
            var next = anchor.Value + k * cycle;
            if (next - n < -50) next += cycle;
            var sec = (next - n) / 1000.0;
            _next.Text = sec >= 0
                ? $"next expected in {sec:F1}s  ({DateTimeOffset.FromUnixTimeMilliseconds((long)next).ToLocalTime():HH:mm:ss})"
                : $"expected was {-sec:F1}s ago";
            _clockLabel.Text = sec >= 0 ? $"{Math.Max(0, sec):F1}s" : "—";
        }

        // streak tally
        var slots = _slotResults.OrderBy(kv => kv.Key).Select(kv => kv.Value).ToList();
        var firstHit = slots.IndexOf(true);
        if (firstHit > 0) slots = slots.Skip(firstHit).ToList();
        else if (firstHit < 0) slots = new List<bool>();
        var hits = slots.Count(x => x);
        var misses = slots.Count(x => !x);
        var total = hits + misses;
        if (total == 0) _tally.Text = "Streak tally: waiting for resolved expected slots…";
        else
        {
            var hitPct = 100.0 * hits / total;
            var missPct = 100.0 * misses / total;
            _tally.Text = $"Hits {hits} ({hitPct:F1}%)   Misses {misses} ({missPct:F1}%)   Total {total}";
            _tally.ForeColor = misses == 0 ? Red : Color.FromArgb(0x9a, 0xaa, 0xbb);
        }
    }

    private void TickWarnAudio()
    {
        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        if (anchor is null) return;
        var cycle = Constants.CycleSec * 1000;
        var n = Constants.NowMs();
        var k = Math.Ceiling((n - anchor.Value) / cycle);
        if (n - anchor.Value < 0) k = 0;
        var next = anchor.Value + k * cycle;
        if (next - n < -50) next += cycle;
        var until = (next - n) / 1000.0;
        if (until <= Constants.WarnSec && until > 0)
        {
            if (_audioTarget != next)
            {
                _audioTarget = next;
                _beeped.Clear();
                _audioResolved = false;
            }
        }
        if (_audioTarget is null) return;
        var slot = _audioTarget.Value;
        var u = (slot - n) / 1000.0;
        if (!_sound)
        {
            if (_audioResolved && u < -2) _audioTarget = null;
            return;
        }
        foreach (var sec in new[] { 3, 2, 1 })
        {
            var key = $"w{sec}";
            if (u <= sec && u > sec - 1 && _beeped.Add(key))
                TonePlayer.Play(TonePlayer.Kind.Warn, 90);
        }
        if (!_audioResolved && u <= 0)
        {
            SpikePoint? spike = null;
            foreach (var s in _viewSpikes)
            {
                if (Math.Abs(s.T - slot) > Math.Max(Constants.OnTimeMs, 300)) continue;
                if (!(s.Large || s.Rtt >= Constants.HighlightMs)) continue;
                if (spike is null || s.Rtt > spike.Rtt) spike = s;
            }
            if (spike is not null && _beeped.Add("hit"))
            {
                _audioResolved = true;
                TonePlayer.Play(TonePlayer.Kind.Hit, Math.Max(120, spike.DurMs));
            }
            else if (n > slot + Constants.OnTimeMs + 600 && _beeped.Add("miss") && !_beeped.Contains("hit"))
            {
                _audioResolved = true;
                TonePlayer.Play(TonePlayer.Kind.Miss, 350);
            }
        }
        if (_audioResolved && u < -2) _audioTarget = null;
    }

    private void DrawClock(Graphics g, Size sz)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Bg);
        var cx = sz.Width / 2f;
        var cy = sz.Height / 2f - 2;
        var r = Math.Min(sz.Width, sz.Height) / 2f - 4;
        using var penBg = new Pen(Grid, 3);
        g.DrawEllipse(penBg, cx - r, cy - r, r * 2, r * 2);

        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        if (anchor is null) return;
        var cycle = Constants.CycleSec * 1000;
        var n = Constants.NowMs();
        var k = Math.Ceiling((n - anchor.Value) / cycle);
        if (n - anchor.Value < 0) k = 0;
        var next = anchor.Value + k * cycle;
        if (next - n < -50) next += cycle;
        var until = Math.Clamp((next - n) / 1000.0, 0, Constants.CycleSec);
        var frac = 1.0 - until / Constants.CycleSec;
        var warn = until <= Constants.WarnSec && until > 0;
        using var pen = new Pen(warn ? Red : Green, 3);
        g.DrawArc(pen, cx - r, cy - r, r * 2, r * 2, -90, (float)(frac * 360));
    }

    private void DrawMap(Graphics g, Size sz)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Bg);
        double t0, t1;
        double? anchor;
        lock (_store.Lock)
        {
            (t0, t1) = _store.Bounds();
            anchor = _store.Anchor;
        }
        var (m0, m1) = MapRange(t0, t1);
        if (!(m1 > m0)) return;
        const int mapLeft = 8;
        var tip = FollowTipMs();
        if (anchor is not null)
        {
            var cycle = Constants.CycleSec * 1000;
            var s = anchor.Value + Math.Floor((m0 - anchor.Value) / cycle) * cycle;
            var guard = 0;
            for (; s <= m1 && guard < 20000; s += cycle, guard++)
            {
                if (s < m0) continue;
                var x = XOf(s, m0, m1, sz.Width, mapLeft);
                using var pen = new Pen(SlotColor(s, tip), s >= tip ? 1.5f : 1.25f);
                g.DrawLine(pen, x, 4, x, sz.Height - 4);
            }
        }
        foreach (var (t, large) in _peakMarks)
        {
            if (t < m0 || t > m1) continue;
            var x = XOf(t, m0, m1, sz.Width, mapLeft);
            using var pen = new Pen(large ? Red : Amber, large ? 1.25f : 1f);
            g.DrawLine(pen, x, 6, x, sz.Height - 6);
        }
        var x1 = XOf(_v0, m0, m1, sz.Width, mapLeft);
        var x2 = XOf(_v1, m0, m1, sz.Width, mapLeft);
        using (var br = new SolidBrush(Color.FromArgb(50, Green)))
            g.FillRectangle(br, x1, 4, Math.Max(3, x2 - x1), sz.Height - 8);
        using (var pen = new Pen(Green, 2))
            g.DrawRectangle(pen, x1, 4, Math.Max(3, x2 - x1), sz.Height - 8);
    }

    private void DrawMain(Graphics g, Size sz)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Bg);
        const float maxRtt = 400;
        var plotH = sz.Height - 40f;
        using (var pen = new Pen(Grid))
        using (var br = new SolidBrush(Dim))
        {
            foreach (var ms in new[] { 0, 63, 100, 200, 300, 400 })
            {
                var y = sz.Height - 20 - ms / maxRtt * plotH;
                g.DrawLine(pen, LeftGutter, y, sz.Width - 10, y);
                g.DrawString(ms.ToString(), _mono, br, 4, y - 6);
            }
        }

        var tip = FollowTipMs();
        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        var slotTimes = new List<double>();
        if (anchor is not null && _v1 > _v0)
        {
            var cycle = Constants.CycleSec * 1000;
            var slot0 = anchor.Value + Math.Floor((_v0 - anchor.Value) / cycle) * cycle;
            var guard = 0;
            for (var s = slot0; s <= _v1 + cycle && guard < 120; s += cycle, guard++)
            {
                if (s < _v0 || s > _v1) continue;
                slotTimes.Add(s);
                var x = XOf(s, _v0, _v1, sz.Width);
                using var pen = new Pen(SlotColor(s, tip), s >= tip ? 1.5f : 1.25f) { DashStyle = DashStyle.Dash };
                g.DrawLine(pen, x, 0, x, sz.Height - 18);
            }
        }

        // sample line + spike peaks in view
        var pts = _viewSamples.Select(s => (s.T, s.Rtt)).ToList();
        foreach (var s in _viewSpikes)
        {
            if (s.T < _v0 || s.T > _v1) continue;
            if (!(s.Large || s.Minor || s.Rtt >= Constants.HighlightMs)) continue;
            pts.Add((s.T, s.Rtt));
        }
        pts.Sort((a, b) => a.T.CompareTo(b.T));
        if (pts.Count > 1)
        {
            using var pen = new Pen(Line, 1.2f);
            var path = new List<PointF>();
            foreach (var (t, rtt) in pts)
            {
                var x = XOf(t, _v0, _v1, sz.Width);
                var y = sz.Height - 20 - (float)(Math.Min(maxRtt, rtt) / maxRtt * plotH);
                path.Add(new PointF(x, y));
            }
            if (path.Count > 1) g.DrawLines(pen, path.ToArray());
        }

        // Collapse multi-flow / sample-peak twins into one marker (peak RTT).
        const double markGapMs = Constants.ClumpGapMs;
        var markList = new List<SpikePoint>();
        foreach (var s in _viewSpikes.OrderBy(x => x.T))
        {
            if (s.T < _v0 || s.T > _v1) continue;
            if (!(s.Large || s.Minor || s.Rtt >= Constants.HighlightMs || _peakMarks.ContainsKey(s.T))) continue;
            if (markList.Count > 0 && s.T - markList[^1].T <= markGapMs)
            {
                var prev = markList[^1];
                if (s.Rtt > prev.Rtt)
                {
                    prev.T = s.T;
                    prev.Rtt = s.Rtt;
                    prev.Large = s.Large || s.Rtt >= Constants.LargeMs;
                    prev.Minor = !prev.Large;
                }
                else if (s.Large || s.Rtt >= Constants.LargeMs)
                {
                    prev.Large = true;
                    prev.Minor = false;
                }
                continue;
            }
            markList.Add(new SpikePoint
            {
                T = s.T,
                Rtt = s.Rtt,
                Large = s.Large || s.Rtt >= Constants.LargeMs,
                Minor = !(s.Large || s.Rtt >= Constants.LargeMs),
            });
        }
        float lastLabelX = float.NegativeInfinity;
        foreach (var s in markList)
        {
            var x = XOf(s.T, _v0, _v1, sz.Width);
            var y = sz.Height - 20 - (float)(Math.Min(maxRtt, s.Rtt) / maxRtt * plotH);
            var large = s.Large;
            using (var pen = new Pen(Color.FromArgb(30, large ? Red : Amber), 1))
                g.DrawLine(pen, x, 6, x, sz.Height - 16);
            var rad = large ? 5f : 3.5f;
            using (var br = new SolidBrush(large ? Red : Amber))
                g.FillEllipse(br, x - rad, y - rad, rad * 2, rad * 2);
            using (var pen = new Pen(Color.White, 0.8f))
                g.DrawEllipse(pen, x - rad, y - rad, rad * 2, rad * 2);
            if (x - lastLabelX < 28) continue;
            lastLabelX = x;
            var label = s.Rtt >= 100 ? $"{s.Rtt:F0}ms" : $"{s.Rtt:F1}ms";
            using var lblBr = new SolidBrush(large ? Red : Amber);
            g.DrawString(label, _mono, lblBr, x + rad + 2, y - 10);
        }

        if (tip >= _v0 && tip <= _v1)
        {
            var x = XOf(tip, _v0, _v1, sz.Width);
            using var pen = new Pen(Color.FromArgb(60, Color.White));
            g.DrawLine(pen, x, 0, x, sz.Height);
        }

        // Bottom times anchored under each expected-slot line
        using (var br = new SolidBrush(Dim))
        {
            var sf = new StringFormat { Alignment = StringAlignment.Center };
            float lastX = float.NegativeInfinity;
            foreach (var t in slotTimes)
            {
                var x = XOf(t, _v0, _v1, sz.Width);
                if (x - lastX < 36) continue; // avoid overlap when zoomed out
                lastX = x;
                var label = DateTimeOffset.FromUnixTimeMilliseconds((long)t).ToLocalTime().ToString("HH:mm:ss");
                g.DrawString(label, _mono, br, new RectangleF(x - 40, sz.Height - 16, 80, 14), sf);
            }
        }
    }

    private void DrawBin(Graphics g, Size sz)
    {
        g.Clear(Bg);
        using (var br = new SolidBrush(Dim))
            g.DrawString("31s", _mono, br, 8, sz.Height / 2f - 6);
        double? anchor;
        lock (_store.Lock) anchor = _store.Anchor;
        if (anchor is null || !(_v1 > _v0)) return;
        var cycle = Constants.CycleSec * 1000;
        var n = FollowTipMs();
        var slot0 = anchor.Value + Math.Floor((_v0 - anchor.Value) / cycle) * cycle;
        const int gap = 2;
        var slots = 0;
        for (var s = slot0; s < _v1 + cycle && slots < 40; s += cycle)
        {
            slots++;
            var s1 = s + cycle;
            if (s1 < _v0 || s > _v1) continue;
            Color fill;
            if (s >= n) fill = Color.FromArgb(0x2e, 0x6e, 0xb5);
            else if (MajorOnTime(s) || (_slotResults.TryGetValue(s, out var h) && h)) fill = Color.FromArgb(0xc0, 0x39, 0x2b);
            else if (_slotResults.TryGetValue(s, out var miss) && !miss) fill = Color.FromArgb(0x1e, 0x84, 0x49);
            else fill = Color.FromArgb(0x3d, 0x4f, 0x61);
            var x1 = XOf(Math.Max(s, _v0), _v0, _v1, sz.Width);
            var x2 = XOf(Math.Min(s1, _v1), _v0, _v1, sz.Width);
            var bw = Math.Max(1, x2 - x1 - gap);
            using var br = new SolidBrush(fill);
            g.FillRectangle(br, x1, 6, bw, sz.Height - 12);
        }
    }

    private void WireInput()
    {
        void OnWheel(object? _, MouseEventArgs e)
        {
            LeaveFollow();
            var anchor = TOf(e.X, _v0, _v1, _main.ClientSize.Width);
            var factor = e.Delta > 0 ? 0.8 : 1.25;
            var span = Math.Clamp((_v1 - _v0) * factor, 5_000, 6 * 60 * 60 * 1000.0);
            var frac = (_main.ClientSize.Width <= LeftGutter) ? 0.5 :
                (e.X - LeftGutter) / (double)Math.Max(1, _main.ClientSize.Width - LeftGutter - 10);
            _v0 = anchor - span * frac;
            _v1 = _v0 + span;
        }
        _main.MouseWheel += OnWheel;

        _main.MouseDown += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            LeaveFollow();
            _dragStart = e.Location;
            _dragV0 = _v0;
            _dragV1 = _v1;
            _main.Capture = true;
        };
        _main.MouseMove += (_, e) =>
        {
            if (_dragStart is null) return;
            var span = _dragV1 - _dragV0;
            var dx = e.X - _dragStart.Value.X;
            var dt = -dx / (double)Math.Max(1, _main.ClientSize.Width - LeftGutter - 10) * span;
            _v0 = _dragV0 + dt;
            _v1 = _dragV1 + dt;
        };
        _main.MouseUp += (_, _) => { _dragStart = null; _main.Capture = false; };

        _map.MouseDown += (_, e) =>
        {
            LeaveFollow();
            double t0, t1;
            lock (_store.Lock) (t0, t1) = _store.Bounds();
            var (m0, m1) = MapRange(t0, t1);
            var t = TOf(e.X, m0, m1, _map.ClientSize.Width, 8);
            var span = _v1 - _v0;
            _v0 = t - span / 2;
            _v1 = t + span / 2;
        };

        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.L) _liveBtn.PerformClick();
            if (e.KeyCode == Keys.T) _followBtn.PerformClick();
            if (e.KeyCode == Keys.S) _soundBtn.PerformClick();
            if (e.KeyCode == Keys.R)
            {
                LeaveFollow();
                lock (_store.Lock)
                {
                    var (t0, t1) = _store.Bounds();
                    if (t1 > t0) { _v0 = t0; _v1 = t1; }
                }
            }
        };
    }
}
