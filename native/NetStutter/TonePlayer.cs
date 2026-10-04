using System.Media;

namespace NetStutter;

/// <summary>
/// Exact port of timeline-web playTone() — same waves, freqs, and gain envelopes
/// as the browser Web Audio API version.
/// </summary>
internal static class TonePlayer
{
    public enum Kind { Warn, Hit, Miss }

    public static void Play(Kind kind, double durationMs = 0)
    {
        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                switch (kind)
                {
                    case Kind.Warn:
                        // playTone("warn", 90)
                        PlayWarn(durationMs > 0 ? durationMs : 90);
                        break;
                    case Kind.Hit:
                        // playTone("hit", dur) — dur from spike, default 120
                        PlayHit(durationMs > 0 ? durationMs : 120);
                        break;
                    case Kind.Miss:
                        PlayMiss();
                        break;
                }
            }
            catch { /* ignore audio failures */ }
        });
    }

    // --- mirrors app.js playTone envelopes sample-for-sample ---

    private static void PlayWarn(double durationMs)
    {
        var dur = Math.Max(0.04, durationMs / 1000.0);
        var stopAt = Math.Min(0.14, dur + 0.02);
        var fadeEnd = Math.Min(0.12, dur);
        Render(stopAt, (t, _) =>
        {
            // square 880 Hz
            var phase = 2 * Math.PI * 880 * t;
            var sample = Math.Sin(phase) >= 0 ? 1.0 : -1.0;
            var g = EnvWarn(t, fadeEnd);
            return sample * g;
        });
    }

    private static double EnvWarn(double t, double fadeEnd)
    {
        // 0.0001 @0 → 0.12 @0.01 → 0.0001 @fadeEnd
        const double g0 = 0.0001, gPeak = 0.12;
        if (t <= 0) return g0;
        if (t < 0.01) return ExpRamp(g0, gPeak, t / 0.01);
        if (t < fadeEnd) return ExpRamp(gPeak, g0, (t - 0.01) / Math.Max(1e-6, fadeEnd - 0.01));
        return g0;
    }

    private static void PlayHit(double durationMs)
    {
        var dur = Math.Max(0.04, durationMs / 1000.0);
        var stopAt = dur + 0.02;
        var sustainAt = Math.Max(0.02, dur - 0.04);
        Render(stopAt, (t, _) =>
        {
            // sawtooth 523.25 Hz (C5)
            var period = 1.0 / 523.25;
            var frac = (t % period) / period; // 0..1
            var sample = 2.0 * frac - 1.0;
            var g = EnvHit(t, dur, sustainAt);
            return sample * g;
        });
    }

    private static double EnvHit(double t, double dur, double sustainAt)
    {
        const double g0 = 0.0001, gPeak = 0.14, gSus = 0.12;
        if (t <= 0) return g0;
        if (t < 0.015) return ExpRamp(g0, gPeak, t / 0.015);
        if (t < sustainAt) return gSus; // setValueAtTime(0.12, ...)
        if (t < dur) return ExpRamp(gSus, g0, (t - sustainAt) / Math.Max(1e-6, dur - sustainAt));
        return g0;
    }

    private static void PlayMiss()
    {
        // triangle 220 Hz; ramp to 0.16 in 0.02s, fade by 0.35s, stop 0.4s
        Render(0.4, (t, _) =>
        {
            var period = 1.0 / 220.0;
            var frac = (t % period) / period;
            // triangle −1..1
            var sample = frac < 0.5 ? (4 * frac - 1) : (3 - 4 * frac);
            var g = EnvMiss(t);
            return sample * g;
        });
    }

    private static double EnvMiss(double t)
    {
        const double g0 = 0.0001, gPeak = 0.16;
        if (t <= 0) return g0;
        if (t < 0.02) return ExpRamp(g0, gPeak, t / 0.02);
        if (t < 0.35) return ExpRamp(gPeak, g0, (t - 0.02) / 0.33);
        return g0;
    }

    private static double ExpRamp(double from, double to, double u)
    {
        u = Math.Clamp(u, 0, 1);
        // WebAudio exponentialRampToValueAtTime
        return from * Math.Pow(to / from, u);
    }

    private static void Render(double seconds, Func<double, int, double> sampleAt)
    {
        const int sampleRate = 44100;
        var n = Math.Max(1, (int)(sampleRate * seconds));
        using var ms = new MemoryStream();
        using (var bw = new BinaryWriter(ms, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            var dataBytes = n * 2;
            bw.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            bw.Write(36 + dataBytes);
            bw.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
            bw.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
            bw.Write(16);
            bw.Write((short)1);
            bw.Write((short)1);
            bw.Write(sampleRate);
            bw.Write(sampleRate * 2);
            bw.Write((short)2);
            bw.Write((short)16);
            bw.Write(System.Text.Encoding.ASCII.GetBytes("data"));
            bw.Write(dataBytes);

            for (var i = 0; i < n; i++)
            {
                var t = i / (double)sampleRate;
                var s = sampleAt(t, i);
                var v = (short)Math.Clamp((int)(s * short.MaxValue), short.MinValue, short.MaxValue);
                bw.Write(v);
            }
            bw.Flush();
        }
        ms.Position = 0;
        using var player = new SoundPlayer(ms);
        player.PlaySync();
    }
}
