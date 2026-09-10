using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace LumenEditor.Windows.App;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var current = AppInstance.GetCurrent();
        var newWindow = args.Any(argument => StringComparer.OrdinalIgnoreCase.Equals(argument, "--new-window"));
        var key = newWindow
            ? $"LumenEditor.Windows.Native.Preview.Window.{Guid.NewGuid():N}"
            : "LumenEditor.Windows.Native.Preview";
        var primary = AppInstance.FindOrRegisterForKey(key);
        if (!primary.IsCurrent)
        {
            primary.RedirectActivationToAsync(current.GetActivatedEventArgs())
                .GetAwaiter().GetResult();
            return;
        }
        Application.Start(_ => new App());
    }

}
