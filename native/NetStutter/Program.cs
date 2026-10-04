using NetStutter.Probe;

namespace NetStutter;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        var store = new DataStore();
        using var probe = new StunProbe(store);
        probe.Start();
        Application.Run(new MainForm(store, probe));
    }
}
