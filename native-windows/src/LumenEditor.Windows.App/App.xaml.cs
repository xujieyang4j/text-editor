using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace LumenEditor.Windows.App;

public partial class App : Application
{
    private MainWindow? window;

    public App()
    {
        InitializeComponent();
        AppInstance.GetCurrent().Activated += OnActivated;
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
        OpenFileActivation(AppInstance.GetCurrent().GetActivatedEventArgs().Data);
    }

    private void OnActivated(object? sender, AppActivationArguments args)
    {
        if (window is null) return;
        window.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Normal, () =>
        {
            window.Activate();
            OpenFileActivation(args.Data);
        });
    }

    private void OpenFileActivation(object? data)
    {
        if (window is null || data is not IFileActivatedEventArgs activated) return;
        _ = window.OpenPathsAsync(activated.Files.OfType<global::Windows.Storage.StorageFile>().Select(file => file.Path));
    }
}
