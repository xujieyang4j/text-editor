using System.Text;
using LumenEditor.Windows.Core.Parsing;
using LumenEditor.Windows.Core.Plugins;

namespace LumenEditor.Windows.Worker;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--parser-worker") return RunParser(args[1]);
        if (args.Length == 4 && args[0] == "--plugin-worker")
            return RunPlugin(args[1], args[2], args[3]);
        Console.Error.WriteLine("Expected --parser-worker or --plugin-worker mode.");
        return 2;
    }

    private static int RunParser(string bundlePath)
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            var host = new CodeMirrorParserWorkerHost(
                CodeMirrorParserWorkerHost.ReadBundle(bundlePath), bundlePath);
            string? line;
            var input = Console.OpenStandardInput();
            while ((line = ReadBoundedLine(input, CodeMirrorParserProtocol.MaximumRequestUtf8Bytes)) is not null)
            {
                var request = CodeMirrorParserCodec.DecodeRequest(line);
                Console.WriteLine(CodeMirrorParserCodec.EncodeResponse(host.Handle(request)));
                Console.Out.Flush();
            }
            return 0;
        }
        catch (Exception error)
        {
            WriteError(error.Message, CodeMirrorParserProtocol.MaximumErrorCharacters);
            return 1;
        }
    }

    private static int RunPlugin(string pluginId, string integrity, string permissionsJson)
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            var permissions = PluginWorkerCodec.DecodePermissions(permissionsJson);
            var host = new PluginWorkerHost(pluginId, integrity, permissions);
            string? line;
            var input = Console.OpenStandardInput();
            while ((line = ReadBoundedLine(input, PluginWorkerProtocol.MaximumMessageBytes)) is not null)
            {
                var request = PluginWorkerCodec.DecodeRequest(line);
                foreach (var response in host.Handle(request))
                    Console.WriteLine(PluginWorkerCodec.Encode(response));
                Console.Out.Flush();
                if (request.Type == PluginWorkerRequestKind.Deactivate) return 0;
            }
            return 0;
        }
        catch (Exception error)
        {
            WriteError(error.Message, PluginWorkerProtocol.MaximumFailureCharacters);
            return 1;
        }
    }

    private static string? ReadBoundedLine(Stream input, int maximumBytes)
    {
        using var line = new MemoryStream();
        while (true)
        {
            var value = input.ReadByte();
            if (value < 0)
            {
                if (line.Length == 0) return null;
                throw new InvalidDataException("Worker input ended with an incomplete message.");
            }
            if (value == 0x0a) break;
            line.WriteByte((byte)value);
            if (line.Length > maximumBytes)
                throw new InvalidDataException("Worker request exceeded its size limit.");
        }
        var bytes = line.ToArray();
        var length = bytes.Length > 0 && bytes[^1] == 0x0d ? bytes.Length - 1 : bytes.Length;
        try { return new UTF8Encoding(false, true).GetString(bytes, 0, length); }
        catch (DecoderFallbackException error)
        {
            throw new InvalidDataException("Worker request was not valid UTF-8.", error);
        }
    }

    private static void WriteError(string message, int maximumCharacters) =>
        Console.Error.WriteLine(message.Length <= maximumCharacters
            ? message : message[..maximumCharacters]);
}
