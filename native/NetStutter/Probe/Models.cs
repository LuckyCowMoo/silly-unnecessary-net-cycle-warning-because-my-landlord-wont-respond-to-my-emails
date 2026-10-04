namespace NetStutter.Probe;

internal sealed class SamplePoint
{
    public double T;
    public double Rtt;
    public string Flow = "";
}

internal sealed class SpikePoint
{
    public double T;
    public double Rtt;
    public bool Large;
    public bool Minor;
    public string Flow = "";
    public double DurMs = 1;
    public int Count = 1;
}
