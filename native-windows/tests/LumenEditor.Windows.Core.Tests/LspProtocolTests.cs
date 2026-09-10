using System.Text;
using LumenEditor.Windows.Core.Language;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class LspProtocolTests
{
    [Fact]
    public void Reader_HandlesSplitAndConcatenatedFrames()
    {
        var first = LspMessageReader.Encode(new { jsonrpc = "2.0", id = 1, result = new { ok = true } });
        var second = LspMessageReader.Encode(new { jsonrpc = "2.0", method = "window/logMessage" });
        var reader = new LspMessageReader();

        Assert.Empty(reader.Append(first.AsSpan(0, 7)).Messages);
        var combined = first[7..].Concat(second).ToArray();
        var output = reader.Append(combined);

        Assert.Empty(output.Errors);
        Assert.Equal(2, output.Messages.Count);
        Assert.Equal(1, output.Messages[0].GetProperty("id").GetInt32());
        Assert.Equal("window/logMessage", output.Messages[1].GetProperty("method").GetString());
    }

    [Fact]
    public void Reader_ReportsBadJsonAndContinuesAtNextFrame()
    {
        var badPayload = Encoding.UTF8.GetBytes("{");
        var bad = Encoding.ASCII.GetBytes($"Content-Length: {badPayload.Length}\r\n\r\n").Concat(badPayload);
        var good = LspMessageReader.Encode(new { jsonrpc = "2.0", id = 2, result = true });
        var reader = new LspMessageReader();

        var output = reader.Append(bad.Concat(good).ToArray());

        Assert.Single(output.Errors);
        Assert.False(output.Errors[0].Fatal);
        Assert.Single(output.Messages);
        Assert.False(reader.IsStopped);
    }

    [Fact]
    public void Reader_StopsOnOversizedHeader()
    {
        var reader = new LspMessageReader();
        var output = reader.Append(Enumerable.Repeat((byte)'a', LspProtocolLimits.MaximumHeaderBytes + 1).ToArray());
        Assert.True(reader.IsStopped);
        Assert.True(Assert.Single(output.Errors).Fatal);
    }
}
