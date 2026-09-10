using System.Text;
using Jint;

namespace LumenEditor.Windows.Core.Parsing;

/// <summary>Loads the trusted frozen parser bundle inside the dedicated helper process.</summary>
public sealed class CodeMirrorParserWorkerHost
{
    private readonly Engine engine;

    public CodeMirrorParserWorkerHost(string bundleSource, string sourceName = "CodeMirrorParserBundle.js")
    {
        if (String.IsNullOrEmpty(bundleSource) || Encoding.UTF8.GetByteCount(bundleSource)
            > CodeMirrorParserProtocol.MaximumBundleBytes)
            throw new InvalidDataException("The parser bundle has an invalid size.");
        engine = new Engine(options =>
        {
            options.Strict().DisableStringCompilation().LimitMemory(384 * 1024 * 1024)
                .TimeoutInterval(TimeSpan.FromSeconds(5)).MaxStatements(10_000_000).LimitRecursion(256);
            options.Interop.Enabled = false;
        });
        engine.Execute(bundleSource, sourceName);
        engine.Execute("if(!globalThis.LumenCodeMirrorParser||typeof globalThis.LumenCodeMirrorParser.analyze!=='function'||globalThis.LumenCodeMirrorParser.protocolVersion!==2)throw new Error('Parser API unavailable');globalThis.__lumenAnalyze=globalThis.LumenCodeMirrorParser.analyze;");
    }

    public CodeMirrorParserResponse Handle(CodeMirrorParserRequest request)
    {
        try
        {
            var requestJson = CodeMirrorParserCodec.EncodeBundleRequest(request);
            var responseJson = engine.Invoke("__lumenAnalyze", requestJson).AsString();
            var result = CodeMirrorParserCodec.DecodeBundleResult(responseJson, request.Text, request.Language);
            return new(CodeMirrorParserProtocol.Version, request.RequestId, result);
        }
        catch (Exception error)
        {
            var message = error.Message;
            if (message.Length > CodeMirrorParserProtocol.MaximumErrorCharacters)
                message = message[..CodeMirrorParserProtocol.MaximumErrorCharacters];
            return new(CodeMirrorParserProtocol.Version, request.RequestId, Error: message);
        }
    }

    public static string ReadBundle(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.IndexOf('\0') >= 0)
            throw new InvalidDataException("The parser bundle path is invalid.");
        var fullPath = Path.GetFullPath(path);
        var info = new FileInfo(fullPath);
        if (!info.Exists || info.Length is <= 0 or > CodeMirrorParserProtocol.MaximumBundleBytes
            || info.Attributes.HasFlag(FileAttributes.Directory)
            || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidDataException("The parser bundle is not a bounded regular file.");
        try { return new UTF8Encoding(false, true).GetString(File.ReadAllBytes(fullPath)); }
        catch (DecoderFallbackException error)
        {
            throw new InvalidDataException("The parser bundle is not valid UTF-8.", error);
        }
    }
}
