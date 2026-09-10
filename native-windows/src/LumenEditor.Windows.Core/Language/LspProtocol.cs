using System.Text;
using System.Text.Json;

namespace LumenEditor.Windows.Core.Language;

public static class LspProtocolLimits
{
    public const int MaximumHeaderBytes = 16 * 1024;
    public const int MaximumPayloadBytes = 8 * 1024 * 1024;
    public const int MaximumPendingBytes = MaximumHeaderBytes + MaximumPayloadBytes + 4;
}

public sealed record LspProtocolError(string Message, bool Fatal);

public sealed record LspReaderOutput(
    IReadOnlyList<JsonElement> Messages, IReadOnlyList<LspProtocolError> Errors);

/// <summary>Incremental, bounded reader for Content-Length framed JSON-RPC messages.</summary>
public sealed class LspMessageReader
{
    private static readonly byte[] Separator = "\r\n\r\n"u8.ToArray();
    private readonly List<byte> pending = [];
    private int? expectedPayloadLength;
    public bool IsStopped { get; private set; }

    public LspReaderOutput Append(ReadOnlySpan<byte> chunk)
    {
        var messages = new List<JsonElement>();
        var errors = new List<LspProtocolError>();
        if (chunk.Length == 0 || IsStopped) return new(messages, errors);
        if (chunk.Length > LspProtocolLimits.MaximumPendingBytes
            || pending.Count > LspProtocolLimits.MaximumPendingBytes - chunk.Length)
        {
            Stop("LSP input exceeded the bounded receive buffer.", errors);
            return new(messages, errors);
        }
        pending.AddRange(chunk.ToArray());

        while (!IsStopped)
        {
            if (expectedPayloadLength is null)
            {
                var separator = FindSeparator(pending);
                if (separator < 0)
                {
                    if (pending.Count > LspProtocolLimits.MaximumHeaderBytes)
                    {
                        Stop($"LSP header exceeds the {LspProtocolLimits.MaximumHeaderBytes}-byte limit.", errors);
                    }
                    break;
                }
                if (separator > LspProtocolLimits.MaximumHeaderBytes)
                {
                    Stop($"LSP header exceeds the {LspProtocolLimits.MaximumHeaderBytes}-byte limit.", errors);
                    break;
                }
                var header = pending.GetRange(0, separator).ToArray();
                pending.RemoveRange(0, separator + Separator.Length);
                if (!TryParseHeader(header, out var length, out var error))
                {
                    Stop(error, errors);
                    break;
                }
                expectedPayloadLength = length;
            }

            var expected = expectedPayloadLength.Value;
            if (pending.Count < expected) break;
            var payload = pending.GetRange(0, expected).ToArray();
            pending.RemoveRange(0, expected);
            expectedPayloadLength = null;
            try
            {
                using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 128 });
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    errors.Add(new("LSP payload must be a JSON object.", false));
                    continue;
                }
                messages.Add(document.RootElement.Clone());
            }
            catch (JsonException)
            {
                errors.Add(new("Invalid JSON in LSP payload.", false));
            }
        }
        return new(messages, errors);
    }

    public static byte[] Encode<T>(T message)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message);
        if (payload.Length > LspProtocolLimits.MaximumPayloadBytes)
        {
            throw new InvalidOperationException("LSP payload exceeds the hard size limit.");
        }
        var header = Encoding.ASCII.GetBytes($"Content-Length: {payload.Length}\r\n\r\n");
        return [.. header, .. payload];
    }

    private static int FindSeparator(List<byte> bytes)
    {
        for (var index = 0; index <= bytes.Count - Separator.Length; index++)
        {
            if (bytes[index] == 13 && bytes[index + 1] == 10
                && bytes[index + 2] == 13 && bytes[index + 3] == 10) return index;
        }
        return -1;
    }

    private static bool TryParseHeader(byte[] bytes, out int length, out string error)
    {
        length = 0;
        error = String.Empty;
        if (bytes.Length == 0 || bytes.Any(value => value > 0x7F))
        {
            error = "LSP header must contain ASCII fields.";
            return false;
        }
        int? contentLength = null;
        foreach (var line in Encoding.ASCII.GetString(bytes).Split("\r\n", StringSplitOptions.None))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0)
            {
                error = "Malformed LSP header.";
                return false;
            }
            var name = line[..colon];
            var value = line[(colon + 1)..].Trim();
            if (!name.All(character => Char.IsAsciiLetterOrDigit(character) || "!#$%&'*+-.^_|~".Contains(character)))
            {
                error = "Malformed LSP header name.";
                return false;
            }
            if (!name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
            if (contentLength is not null || !Int32.TryParse(value, out var parsed) || parsed < 0)
            {
                error = "Invalid or duplicate LSP Content-Length header.";
                return false;
            }
            contentLength = parsed;
        }
        if (contentLength is null)
        {
            error = "Missing LSP Content-Length header.";
            return false;
        }
        if (contentLength > LspProtocolLimits.MaximumPayloadBytes)
        {
            error = $"LSP payload exceeds the {LspProtocolLimits.MaximumPayloadBytes}-byte limit.";
            return false;
        }
        length = contentLength.Value;
        return true;
    }

    private void Stop(string message, List<LspProtocolError> errors)
    {
        IsStopped = true;
        pending.Clear();
        expectedPayloadLength = null;
        errors.Add(new(message, true));
    }
}
