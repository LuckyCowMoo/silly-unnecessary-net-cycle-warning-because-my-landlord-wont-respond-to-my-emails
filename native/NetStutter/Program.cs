using NetStutter.Probe;

namespace NetStutter;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        ApplicationConfiguration.Initialize();
        var store = new DataStore();
        using var probe = new StunProbe(store);
        probe.Start();
        Application.Run(new MainForm(store, probe));
    }
}
