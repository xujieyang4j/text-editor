using System.Text;
using LumenEditor.Windows.Core.Plugins;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class PluginWorkerProtocolTests
{
    [Fact]
    public void Codec_RoundTripsLoadAndRejectsIntegrityMismatch()
    {
        const string source = "self.onmessage = function () {}";
        var integrity = PluginIntegrity.Compute(Encoding.UTF8.GetBytes(source));
        var request = new PluginWorkerRequest(1, PluginWorkerRequestKind.Load, "load-1", source, integrity);
        Assert.Equal(request, PluginWorkerCodec.DecodeRequest(PluginWorkerCodec.Encode(request)));
        Assert.Contains("\"run-command\"", PluginWorkerCodec.Encode(request with
            { Type = PluginWorkerRequestKind.RunCommand, CommandId = "run", Source = null, SourceIntegrity = null }));
        Assert.Equal("[\"document-read\"]",
            PluginWorkerCodec.EncodePayload(new[] { PluginPermission.DocumentRead }));
        Assert.Throws<InvalidDataException>(() => PluginWorkerCodec.Encode(request with { Source = "changed" }));
    }

    [Fact]
    public void Codec_EnforcesPermissionPayloadAndResponseBounds()
    {
        var document = new PluginWorkerDocument("hello", "plain", new PluginWorkerSelection(1, 4));
        var context = new PluginWorkerContext([PluginPermission.DocumentRead], document);
        var request = new PluginWorkerRequest(1, PluginWorkerRequestKind.Activate, "activate", Context: context);
        Assert.Equal(document, PluginWorkerCodec.DecodeRequest(PluginWorkerCodec.Encode(request)).Context?.Document);
        Assert.Throws<InvalidDataException>(() => PluginWorkerCodec.Encode(new PluginWorkerResponse(
            1, PluginWorkerResponseKind.Notify, "request", Text: new string('x', 501))));
        Assert.Throws<InvalidDataException>(() => PluginWorkerCodec.Encode(new PluginWorkerRequest(
            1, PluginWorkerRequestKind.Activate, "activate", Context: new([], document))));
    }
}
