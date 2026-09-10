using System.Text;
using LumenEditor.Windows.Core.Plugins;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class PluginWorkerHostTests
{
    [Fact]
    public void Host_LoadsActivatesAndRunsBoundedWorker()
    {
        const string source = "self.onmessage=function(e){if(e.data.type==='activate')postMessage({type:'register-command',id:'hello',title:'Hello'});if(e.data.type==='run-command')postMessage({type:'notify',text:e.data.id});}";
        var integrity = PluginIntegrity.Compute(Encoding.UTF8.GetBytes(source));
        var host = new PluginWorkerHost("safe", integrity, []);

        Assert.Equal(PluginWorkerResponseKind.Completed, Assert.Single(host.Handle(new(
            1, PluginWorkerRequestKind.Load, "load", source, integrity))).Type);
        var activated = host.Handle(new(1, PluginWorkerRequestKind.Activate, "activate", Context: new([], null)));
        Assert.Equal(PluginWorkerResponseKind.RegisterCommand, activated[0].Type);
        Assert.Equal("hello", activated[0].Id);
        var run = host.Handle(new(1, PluginWorkerRequestKind.RunCommand, "run", CommandId: "hello", Context: new([], null)));
        Assert.Equal("hello", run[0].Text);
        Assert.Equal(PluginWorkerResponseKind.Completed, run[^1].Type);
    }

    [Fact]
    public void Host_EnforcesEditPermissionAndExecutionBudget()
    {
        const string editSource = "self.onmessage=function(){postMessage({type:'replace-document',text:'changed'});}";
        var editIntegrity = PluginIntegrity.Compute(Encoding.UTF8.GetBytes(editSource));
        var editHost = new PluginWorkerHost("safe", editIntegrity, []);
        _ = editHost.Handle(new(1, PluginWorkerRequestKind.Load, "load", editSource, editIntegrity));
        Assert.Equal(PluginWorkerResponseKind.Failed, editHost.Handle(new(
            1, PluginWorkerRequestKind.Activate, "activate", Context: new([], null)))[^1].Type);

        const string loopSource = "while(true){}";
        var loopIntegrity = PluginIntegrity.Compute(Encoding.UTF8.GetBytes(loopSource));
        var loopHost = new PluginWorkerHost("loop", loopIntegrity, []);
        Assert.Equal(PluginWorkerResponseKind.Failed, Assert.Single(loopHost.Handle(new(
            1, PluginWorkerRequestKind.Load, "load", loopSource, loopIntegrity))).Type);
    }
}
