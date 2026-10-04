namespace NetStutter.Probe;

/// <summary>Keep in lockstep with Serve-SpikeTimeline.py — detection parity.</summary>
internal static class Constants
{
    public const double CycleSec = 31.0;
    public const double LargeMs = 200.0;
    public const double HighlightMs = 75.0;
    public const double SpikeMs = 75.0;
    public const double OnTimeMs = 100.0;
    public const int MinSegSamples = 8;
    public const double ClumpGapMs = 400.0;
    public const int DefaultRateHz = 60;
    public static readonly int[] RateChoices = { 60, 120, 240 };
    public const double TimeoutMs = 1500;
    public const double KeepMs = 6 * 60 * 60 * 1000;
    public const double LiveBackSec = 1.5 * 60;
    public const double LiveAheadSec = 45;
    public const double WarnSec = 3;

    public static readonly (string Host, int Port)[] StunServers =
    {
        ("stun.l.google.com", 19302),
        ("stun1.l.google.com", 19302),
        ("stun.cloudflare.com", 3478),
    };

    public static readonly byte[] Magic = { 0x21, 0x12, 0xa4, 0x42 };

    public static double NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}
